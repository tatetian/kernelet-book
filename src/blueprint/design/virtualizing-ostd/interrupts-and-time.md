# Interrupts and time

*Part of question 2. Virtualizes `irq` and `timer`. Discharges the interrupt-context half of invariant I7: no kernelet code ever runs in interrupt context, so a kernelet task can always be terminated where it stands.*

A kernelet has no interrupts. The host owns the interrupt descriptor table, the interrupt controller and every physical line; nothing a kernelet does can register a handler with them, mask them, or send one (absent `smp`, `IRQ_CHIP`, `disable_local` in its real sense). What a kernelet has instead is **virtual interrupt lines** raised by the endovisor, **jobs** delivered to its per-virtual-CPU **workers**, and a **tick** the host posts at the kernel's own frequency while the kernelet is busy. The kernel proper's drivers, bottom halves and timers keep their code and run in task context on the worker.

## Virtual interrupt lines

```rust
// OSTD (kernelet build), the virtualized `IrqLine`. Same public API as the host build's.
pub struct IrqLine { virq: u8, callbacks: Vec<CallbackHandle> }
static LINES: [SpinLock<Vec<Box<IrqCallbackFunction>>>; 256];   // in KW_DATA, indexed by virq
static ALLOCATOR: SpinLock<IdAlloc>;                              // virqs 32..=255
```

`IrqLine::alloc` takes a free virtual line; `alloc_specific(n)` takes line `n`, which is how the virtio MMIO transport binds the line `BootArgs` lists for a device ([Devices](devices.md)). `on_active` pushes the callback into the line's kernelet-side list; `is_empty` and `num` read it; `remapping_index` is absent, since remapping is the host's. A line is raised only by the host, through `Kernelet::raise_irq(virq)` on the control half, which the endovisor's device models call from a hook or a device thread when a request completes. The host sets the line's pending bit and wakes the worker of the virtual CPU the line is bound to; every line is bound to virtual CPU 0 unless the endovisor's device description says otherwise, and the binding is fixed for the kernelet's life.

## Workers and the job loop

Each virtual CPU has one worker, a host task spawned by `create` with `run_task(1, vcpu)`, pinned to that virtual CPU's host CPU and given the highest priority in the kernelet's group, so that a job is served before any of the kernelet's threads on that CPU, which is what interrupt priority gives a real kernel. Its body is in OSTD (kernelet build):

```rust
// OSTD (kernelet build), ostd/src/kernelet_side/worker.rs
extern "C" fn worker_main(vcpu: u64) -> ! {
    loop {
        let mut job = JobDesc::default();
        if services().job_wait(&mut job) < 0 { break; }            // -CANCEL: the kernelet is dying
        rcu::note_quiescent(vcpu);                                   // the top of the loop is a quiescent state
        match job.kind {
            JOB_VIRQ  => deliver_virq(job.arg as u8),
            JOB_TICK  => deliver_tick(job.arg, job.arg2),
            JOB_GRANT => grant::take_and_map_new_grains(),
            JOB_CANCEL => break,
            _ => {}
        }
    }
    services().task_exit()
}

fn deliver_tick(interrupted: u32, privilege: u64) {
    let _guard = disable_preempt();
    let _as = current_task_override(interrupted);          // `Task::current()` names the interrupted task while the tick runs
    level::enter_virtual(InterruptLevel::L1(privilege.into()), || {
        timer::call_timer_callback_functions();            // identical: raises the timer softirq, charges CPU time
        bottom_half::process(TIMER_VIRQ);                  // the timer softirq runs here, as after every interrupt on the tree
    });
}

fn deliver_virq(virq: u8) {
    let frame = TrapFrame::synthetic(virq);               // zeroed, trap number = virq; drivers ignore it
    let _guard = disable_preempt();                        // the interrupt-disabled state a top half expects
    level::enter_virtual(InterruptLevel::L1, || {
        for cb in LINES[virq].lock().iter() { cb(&frame); }
        bottom_half::process(virq);                        // the identical L1 and L2 bottom-half hooks
    });
}
```

`job_wait` returns one job at a time; delivery is edge-triggered on the host side, so a line raised while its handler runs is the next job. The callbacks run exactly as they would in a top half on the host kernel: with preemption disabled in place of interrupts disabled, and with `InterruptLevel::current()` reporting `L1`, so that code which asks `is_interrupt_context()` to choose a non-sleeping path, the softirq component's lock and `Taskless` among them (checked on the tree: `kernel/core/comps/softirq`), chooses it. That makes `InterruptLevel` a virtualized item: OSTD's `level::enter` records the level in per-CPU state around a real top half (checked on the tree: `ostd/src/irq/level.rs`), and the kernelet build records it in the replica around a delivered job. `register_bottom_half_handler_l1` and `_l2` are the identical hooks; `bottom_half::process` calls them after each delivered line as it does after each real one.

What differs from a real top half is that the worker is a task: it can be preempted by the host if its preemption count is zero, which a top half never is, and it can sleep, which a top half must not. The first cannot happen inside `deliver_virq`, since the count is held; the second is a bug in a driver that would also be a bug on the host kernel. A kernelet's worker is never entered by the host; it fetches its own work, which is what keeps the entry rule and the single-bit depth of invariant I7 true ([service half](../kernelet-api-service.md)).

## `disable_local` and the guardians

`irq::disable_local` and `DisabledLocalIrqGuard` are virtualized without a crossing to a preemption-disable guard: the same type name, the same `GuardTransfer` and `PinCurrentCpu` implementations, a `preempt_count` increment instead of a `cli`. The guardians `LocalIrqDisabled` and `WriteIrqDisabled`, and `SpinLock::disable_irq`, follow: a lock the kernel proper takes with interrupts disabled is a lock it takes with preemption disabled in a kernelet. This is sound because the only thing interrupt disabling excludes on the host kernel is a handler on the same CPU, and a kernelet has no handlers: its "handlers" are jobs on the worker task, which cannot run on this CPU while this task holds preemption off. The kernel proper's `pre_user_run` hook, which takes a `&DisabledLocalIrqGuard` and loads the thread's FS base, GS base and FPU state into the CPU (checked on the tree), gets the aliased guard and is correct for the same reason: the host does not move a task whose count is nonzero ([Tasks](tasks.md)).

## Time

`TIMER_FREQ` is identical, 1000 Hz on the tree. `Jiffies::elapsed` is virtualized without a crossing: it reads the host-wide clock page's `jiffies`, so time inside a kernelet is the host's time, advancing whether or not the kernelet runs. `register_callback_on_cpu` stores its callback in the calling virtual CPU's replica, as on the host, and the callbacks run on that virtual CPU's worker when a `JOB_TICK` arrives, under a preemption guard, in the order registered, with `call_timer_callback_functions` otherwise identical (checked on the tree: `ostd/src/timer/mod.rs`), and the bottom halves run after them, as they run after every interrupt on the tree, the timer's included; the kernel proper's timer wheel advances in that softirq (checked: `kernel/core/src/time/softirq.rs`).

**Whom a tick charges.** The kernel proper's tick callbacks charge CPU time to the thread the tick interrupted, through `Thread::current()`, and split user from system time through `InterruptLevel::current()` (checked on the tree: `time/cpu_time_stats.rs`, `process/process/timer_manager.rs`). On the worker both would name the worker, so a `JOB_TICK` carries the task the host's tick interrupted on that virtual CPU and its privilege level, and while the callbacks run the kernelet build makes `Task::current()` return that task and `InterruptLevel::current()` report `L1` at that privilege. The interrupted task may by then be running on another host CPU; the callbacks touch only its thread's shared, synchronized state, never its task-local data. **[unverified]** (register A10): that every tick callback in the kernel proper respects that, so that no `cfg` line is needed; the fallback is one line in each of the two files, reading the interrupted thread from an accessor instead of `Thread::current()`.

**When ticks arrive.** A real tick fires on every CPU every millisecond whether the CPU is busy or idle. Posting that to every kernelet would cost one worker wakeup per millisecond per virtual CPU per kernelet, most of them for kernelets with nothing to do, so the host posts ticks under two rules:

- A *busy* virtual CPU, one on whose host CPU a task of the kernelet ran during the last tick period, gets `JOB_TICK` at `TIMER_FREQ`. This keeps the kernel proper's per-CPU accounting, scheduler statistics and timer wheel exactly as timely as on the host kernel while the kernelet is running.
- An *idle* kernelet, one none of whose tasks ran during the period, gets `JOB_TICK` on virtual CPU 0 only, at the reduced rate `policy.idle_tick_hz`, 100 Hz by default. The kernel proper's timer wheel is advanced by the tick softirq (checked on the tree: `kernel/core/src/time/softirq.rs`), so a sleeping process whose timer expires is woken within 10 ms rather than 1 ms while its kernelet is idle; with `idle_tick_hz = 0` an idle kernelet costs nothing and its timers wait for the next event that wakes it.

`timer_arm(vcpu, deadline)` is the one-shot behind the second rule's extension: a `cfg` line in the kernel proper's timer manager can report the earliest pending deadline, and OSTD (kernelet build) would arm it and let the host stop idle ticks entirely. The design permits that line but does not require it; without it, `idle_tick_hz` is the tenant-visible timer latency of an idle sandbox.

## What a tenant sees

- Timer latency for a sleeping process in an idle kernelet is up to `1 / idle_tick_hz` (10 ms by default) instead of 1 ms; while the kernelet is busy it is 1 ms as on the host kernel.
- Interrupt latency for a virtual device is a worker wakeup after the endovisor raises the line, plus the worker's scheduling in the kernelet's group; the Evaluation chapter measures it against a virtio interrupt in a microVM.
- `/proc/interrupts` shows virtual lines 32 and above, one per device; `/proc/softirqs` behaves as on the host kernel, per virtual CPU.
- Nothing else: drivers, bottom halves and timers behave as on the host kernel.

## Costs

- Per virtual interrupt: one `raise_irq` (an atomic or and a wakeup), one `job_wait` return on the worker, and the handler; *estimated* at one context switch and a few hundred cycles of bookkeeping, to be measured.
- Per tick on a busy virtual CPU: one worker wakeup and the callbacks, replacing a hardware interrupt on the host kernel.
- Per idle kernelet: `idle_tick_hz` wakeups per second on one worker.
- Per virtual CPU: the worker's task and stack.
- Per `disable_local`: one store, against a `cli` and `sti` pair.

## What this page decides

- **Virtual interrupts are jobs on per-virtual-CPU workers, fetched, never pushed** (registers D9 and D11): the host never enters kernelet code except at task start.
- **`InterruptLevel` is virtualized to report the delivered level** (register D18). The alternative, leaving it identical so that it always reports task context, would make the kernel proper's interrupt-context checks pick sleeping paths inside a delivered handler, where the worker holds preemption off.
- **Ticks are rate-limited when a kernelet is idle** (register D19), with the rate a policy and a one-shot timer as the extension toward a tickless kernelet. The alternative, ticking every kernelet at 1 kHz per virtual CPU, makes the cost of an idle sandbox a thousand wakeups per second per CPU.
