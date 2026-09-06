# The kernelet API: service half

*Answers question 3: what API does OSTD (host build) expose to OSTD (kernelet build), and how does a call cross from the kernelet image into the host?*

The service half is what a kernelet gets from the host at run time. Its wire form, the **image ABI**, is two tables of `extern "C"` function pointers and three kinds of shared page; its implementation is the module `ostd::kernelet::service` in the host build. Every virtualized item on the [taxonomy](virtualizing-ostd/index.md) bottoms out in one of the functions on this page, and every function here is specified with its signature, what it checks, and what it costs. Invariants enforced here: I1 (reach), the service side of I2 (ownership), I4 (no retained reference), I5 (no closure crosses), I6 (charged work) and the counter behind I7 (termination).

The tables and the shared-page layouts are defined once, in a module compiled into both builds, `ostd::kernelet::abi`, with no `cfg` inside it, so the two sides cannot disagree on a field.

## How the host knows who is calling

A service function takes no kernelet or task argument. The host learns both from its own per-CPU area, which the scheduler keeps current on every switch:

```rust
// ostd::kernelet::abi — read by both builds; written only by the host scheduler.
#[repr(C)]
pub struct CpuSlot {
    /// The kernelet whose task is running on this CPU, or `NONE`.
    pub kernelet: u16,        // slot index; the generation is in the kernelet's own record
    pub vcpu: u16,            // this CPU's index in the kernelet's CPU set
    pub task: u32,            // the running task's name, `TaskName`
    pub generation: u32,      // the kernelet's generation, so a stale slot is detected
    pub _reserved: u32,
}
```

The slot lives in the host's per-CPU storage at an offset published in `BootArgs::cpu_slot_gs_offset`; OSTD (kernelet build) reads it with one GS-relative load. Reading `task` needs no preemption guard, for the reason OSTD's own `Task::current` needs none: a task that migrates reads its own name on the new CPU. Reading `vcpu` requires preemption disabled, as every per-CPU read does.

A **task name** is a `u32` index into the kernelet's task table, unique for the kernelet's life; the host maps it to its `Arc<Task>` in constant time. Names, not pointers, are what cross (invariant I4).

## The shared pages

Three regions of `KW_SHARED` are host frames mapped into the kernelet's window ([Builds and images](builds-and-images.md#window)).

**The boot arguments**, read-only, one or more pages at `KW_SHARED + 0`, written once at creation:

```rust
#[repr(C)]
pub struct BootArgs {
    pub size: u32, pub version: u32,
    pub kernelet: u16, pub generation: u32,
    pub num_vcpus: u16,
    /// Host CPU of each virtual CPU, in order.
    pub vcpu_host_cpu: [u16; MAX_VCPUS],           // MAX_VCPUS = 256
    pub cpu_slot_gs_offset: u32,
    pub cpu_local_replica_bytes: u32,
    /// The kernelet's kernel page table root and the physical address of its
    /// window level-3 table, so that OSTD (kernelet build) can map inside the window.
    pub kernel_pt_root: u64, pub window_l3: u64,
    /// The initial grant: `num_grains` entries of `GrainDesc` follow the struct.
    pub num_grains: u32, pub max_grains: u32,
    /// Devices: `num_devices` entries of `DeviceEntry` follow the grains.
    pub num_devices: u16,
    /// Offsets, from `KW_SHARED`, of the info page and the task-record array.
    pub info_page: u32, pub task_records: u32, pub max_tasks: u32,
    pub tsc_freq_hz: u64,
    /// The command line follows the devices: `cmdline_len` bytes.
    pub cmdline_len: u32,
}
#[repr(C)] pub struct GrainDesc { pub paddr: u64, pub slot: u32, pub _pad: u32 }
#[repr(C)] pub struct DeviceEntry { pub id: u16, pub kind: u16, pub irq: u8, pub _pad: [u8; 3], pub reg_bytes: u32, pub device_type: u32 }
```

**The info page**, read-only to the kernelet, one page, updated by the host while the kernelet runs:

```rust
#[repr(C)]
pub struct InfoPage {
    /// The host's tick counter; `Jiffies::elapsed()` in the kernelet reads this.
    pub jiffies: AtomicU64,
    /// Monotonic nanoseconds since host boot.
    pub monotonic_ns: AtomicU64,
    /// Set once by `kill`; every service call after it fails with `DYING`.
    pub dying: AtomicU32,
    /// Grains granted after boot are published here as a ring the kernelet drains
    /// with `grains_take`; the count is what has been granted in total.
    pub grains_granted: AtomicU32,
    pub epoch: AtomicU32,
}
```

**The task records**, read-write, `max_tasks` records of 64 bytes at `KW_SHARED + task_records`, indexed by task name:

```rust
#[repr(C, align(64))]
pub struct TaskRecord {
    /// Written by the kernelet: its preemption-disable count for this task.
    /// Read by the host tick to decide whether kernel-mode preemption is allowed.
    pub preempt_count: AtomicU32,
    /// Written by the host: NEED_RESCHED, DYING, CANCEL_PARK. Read by the kernelet at
    /// its preemption points and on return from a park.
    pub flags: AtomicU32,
    /// Written by the host on every service entry and exit: 0 in kernelet code,
    /// 1 inside a service call. Read by the host's kill path; this is invariant I7's counter.
    pub service_depth: AtomicU32,
    /// Written by the host at task creation: the task's virtual CPU affinity mask
    /// index and the name, for the kernelet's own bookkeeping.
    pub vcpu_mask: u32, pub name: u32,
    pub _reserved: [u32; 10],
}
```

Everything in these pages is a plain integer. The host writes them through its linear-map alias of the frames, never through a window address, so no host code holds a window pointer (invariant I4).

## The entry table

Read by the host from `KW_TEXT + 4 KiB` of the kernelet image at registration ([Builds and images](builds-and-images.md#entry)); never executed by the host except through the task trampoline, at service-call depth zero.

```rust
#[repr(C)]
pub struct EntryTable {
    pub size: u32, pub version: u32,
    /// The body of a spawned task. Called by the host's task trampoline on a fresh
    /// task, on the kernelet's page table, with `entry` and `arg` from the spawn.
    /// Never returns: it ends with `task_exit`.
    pub run_task: extern "C" fn(entry: u32, arg: u64) -> !,
    /// Bounds of the image's exception table, for kernel-mode faults in user copies
    /// ([User mode](virtualizing-ostd/user-mode.md)). Both inside `KW_TEXT`.
    pub ex_table_start: u64, pub ex_table_end: u64,
    /// Bounds of the image's `.cpu_local` section, which the host replicates per
    /// virtual CPU after the writable segment. Both inside `KW_DATA`.
    pub cpu_local_start: u64, pub cpu_local_end: u64,
    /// Hash of the OSTD source tree and toolchain the image was built from;
    /// must equal the host build's, or registration fails.
    pub source_hash: [u8; 32],
}
```

`run_task` with `entry == 0` is the boot task: it never comes from a spawn, and it is the body that `_kernelet_entry` runs after initializing OSTD (kernelet build). Every other entry index names a closure the kernelet stored in its own heap before calling `task_spawn` ([Tasks](virtualizing-ostd/tasks.md)); the host never sees the closure, only the index (invariant I5).

## The service table

```rust
#[repr(C)]
pub struct ServiceTable {
    pub size: u32, pub version: u32,

    // Memory
    pub grains_take: extern "C" fn(out: *mut GrainDesc, cap: u32) -> i32,
    pub grains_request: extern "C" fn(count: u32) -> i32,
    pub pt_root_register: extern "C" fn(root_paddr: u64) -> i32,
    pub pt_root_unregister: extern "C" fn(root_paddr: u64) -> i32,
    pub pt_activate: extern "C" fn(root_paddr: u64) -> i32,
    pub tlb_shootdown: extern "C" fn(root_paddr: u64, start: u64, len: u64) -> i32,

    // Tasks
    pub task_spawn: extern "C" fn(entry: u32, arg: u64, vcpu_mask: u32, prio: u32) -> i64,
    pub task_exit: extern "C" fn() -> !,
    pub task_yield: extern "C" fn(),
    pub task_park: extern "C" fn() -> i32,
    pub task_unpark: extern "C" fn(name: u32) -> i32,
    pub task_set_prio: extern "C" fn(name: u32, prio: u32) -> i32,
    pub task_set_vcpu_mask: extern "C" fn(name: u32, vcpu_mask: u32) -> i32,

    // Jobs and interrupts
    pub job_wait: extern "C" fn(out: *mut JobDesc) -> i32,
    pub tick_enable: extern "C" fn(enable: u32) -> i32,
    pub timer_arm: extern "C" fn(deadline_ns: u64) -> i32,

    // User mode
    pub user_run: extern "C" fn(ctx: *mut RawUserContext) -> i32,

    // Devices
    pub mmio_read: extern "C" fn(dev: u16, offset: u32, width: u8, out: *mut u64) -> i32,
    pub mmio_write: extern "C" fn(dev: u16, offset: u32, width: u8, value: u64) -> i32,
    pub irq_ack: extern "C" fn(virq: u8) -> i32,

    // Output and end of life
    pub log_write: extern "C" fn(level: u8, module: *const u8, module_len: u32, text: *const u8, text_len: u32) -> i32,
    pub console_write: extern "C" fn(bytes: *const u8, len: u32) -> i32,
    pub exit: extern "C" fn(code: u32) -> !,
    pub panic: extern "C" fn(msg: *const u8, len: u32) -> !,
}

#[repr(C)]
pub struct JobDesc { pub kind: u32, pub arg: u32, pub arg2: u64 }
pub const JOB_VIRQ: u32 = 1; pub const JOB_TICK: u32 = 2; pub const JOB_GRANT: u32 = 3; pub const JOB_CANCEL: u32 = 4;
```

Twenty-four functions. Return values are `0` or a positive count on success and a negative code on failure: `-DYING` (the kernelet was killed), `-NOT_OWNED` (a physical address outside the grant), `-INVALID` (a bad name, index or width), `-LIMIT` (a quota or `max_grains` reached), `-STATE` (the call is not legal now). Pointer arguments are read or written only during the call, and always point into the kernelet's window or its shared pages, which the host validates by range before touching (invariant I4).

### The prologue and epilogue every function shares

```rust
// ostd::kernelet::service, host build; the body of the wrapper each table entry points at.
fn enter() -> Result<Entered, i32> {
    let slot = cpu_slot();                              // one GS-relative load
    let k = slot_table().get(slot.kernelet, slot.generation).ok_or(-INVALID)?;
    let rec = k.task_record(slot.task);
    rec.service_depth.store(1, Relaxed);                // invariant I7: now in host code
    if k.info.dying.load(Acquire) != 0 { return Err(-DYING); }   // except `exit`, `panic`, `task_park`
    stack_check(k, slot.task)?;                          // remaining stack ≥ RESERVE, or the task is killed
    k.accounts.service_calls.fetch_add(1, Relaxed);     // invariant I6
    Ok(Entered { k, rec })
}
fn leave(e: Entered) {
    e.rec.service_depth.store(0, Relaxed);
    if e.rec.flags.load(Acquire) & DYING != 0 { terminate_current_task(); }   // a quiescent point
}
```

The stack check compares the current stack pointer with the task's stack base plus `STACK_RESERVE`, 64 KiB *estimated*, the amount the deepest host path a service call can take (a device model's I/O submission through a host file system) is allowed; a task below the reserve is killed rather than allowed to overflow into the guard page, because a double fault in ring 0 has no stack to take it on (OSTD today has no double-fault handler; measured on the tree). *Estimated cost of prologue and epilogue together:* one GS load, one slot-table index, two stores, three loads and two compares, about 20 cycles, on top of the indirect call itself. The earlier prototype measured a bare crossing at 35 cycles against 34 for a plain call, without this prologue.

### Memory

- `grains_take(out, cap)`: copies up to `cap` descriptors of grains granted since the last call into `out`, returns the count. The initial grant is in `BootArgs`; grants after boot arrive here after a `JOB_GRANT` job. Each descriptor's `slot` fixes the grain's address in `KW_HEAP`; the host has already recorded the grain in the owner array. *Checks:* `out` inside the window. *Cost:* a copy of `count × 16` bytes.
- `grains_request(count)`: asks for more memory now. Returns the number granted at once from the reserve within `max_grains`, or `0`, after calling `KerneletHooks::on_grant_exhausted` if the policy allows. *Cost:* the hook.
- `pt_root_register(root)`, `pt_root_unregister(root)`: the kernelet built a user page table whose root frame is `root`; the host records it so that `pt_activate` and the scheduler accept it, and so that destroy can find every root. *Checks:* `root` is in the grant and not already registered. *Cost:* one owner-array read, one insertion in the kernelet's root set.
- `pt_activate(root)`: writes CR3 with `root` for the current task and records `root` as the task's address space so that the scheduler restores it on every switch to this task. *Checks:* `root` registered. *Cost:* the CR3 write and, since window mappings are not Global, the loss of the window's translations.
- `tlb_shootdown(root, start, len)`: invalidates `[start, start+len)` on every host CPU on which `root` is or may be active, by inter-processor call, and waits. The kernelet cannot send interrupts (absent `smp`), so this is how its `TlbFlusher` completes. *Checks:* `root` registered; `start..len` inside the user half or the window. *Cost:* one IPI per target CPU plus the wait; the target set is bounded by the kernelet's CPU set.

The window's own sub-tables (level 2 and level 1 under the window's level-3 table) are written by OSTD (kernelet build) with frames from its grant, so mapping a grain into `KW_HEAP` or a metadata chunk into `KW_META` needs no service call ([Memory](virtualizing-ostd/memory.md)). The host owns only the level-3 table and its mappings of `KW_TEXT` and `KW_SHARED`.

### Tasks

- `task_spawn(entry, arg, vcpu_mask, prio) -> name`: creates a host task whose body is the trampoline that calls `EntryTable::run_task(entry, arg)` on the kernelet's kernel page table, with a fresh 512 KiB kernel stack, in the kernelet's scheduling group, with affinity the host CPUs of `vcpu_mask`, and makes it runnable. *Checks:* the kernelet's task limit; `vcpu_mask` a subset of the CPU set. *Cost:* a kernel stack allocation and a task object, the same as `TaskOptions::spawn` today plus one record initialization.
- `task_exit() -> !`: the current task ends. The host reaps the task object and its stack after switching away; the name is retired. No kernelet destructor runs on the host's behalf.
- `task_yield()`: the current task yields within its group.
- `task_park() -> 0 | -CANCEL`: parks the current task until `task_unpark(name)` or a cancellation. A park that finds `CANCEL_PARK` set returns at once with `-CANCEL`; a park interrupted by `kill` returns `-CANCEL` too, and the epilogue then terminates the task. This is the primitive under every sleeping lock and wait queue in the kernelet ([Tasks](virtualizing-ostd/tasks.md)).
- `task_unpark(name)`: makes the named task runnable if parked. *Checks:* the name is this kernelet's. *Cost:* the scheduler's enqueue.
- `task_set_prio(name, prio)`, `task_set_vcpu_mask(name, mask)`: the kernelet's say over its own tasks, within its group; the host scheduler decides across groups.

### Jobs, interrupts and time

- `job_wait(out) -> 0`: parks the calling task, which must be the kernelet's worker, until a job is posted, then writes it into `out`. Jobs are: a virtual interrupt (`JOB_VIRQ`, with the line number), a timer tick (`JOB_TICK`), a new grant (`JOB_GRANT`), or a cancellation because the kernelet is dying (`JOB_CANCEL`). The host coalesces: a line raised twice before it is acknowledged is one job. *Checks:* the caller is the worker. *Cost:* a park and an unpark per job; the delivery latency of a virtual interrupt is therefore a wakeup, which the Evaluation chapter will measure.
- `tick_enable(enable)`: turns the kernelet's timer tick on or off. While on, the host posts `JOB_TICK` at `TIMER_FREQ` (1000 Hz) whenever the kernelet has a runnable task; the kernel proper's per-tick callbacks run on the worker ([Interrupts and time](virtualizing-ostd/interrupts-and-time.md)).
- `timer_arm(deadline_ns)`: a one-shot: post `JOB_TICK` at `deadline_ns` on the host's monotonic clock, or at once if past. Lets an idle kernelet sleep without ticks.
- `irq_ack(virq)`: clears the pending bit so the line can be raised again.

### User mode

- `user_run(ctx) -> 0 | 1 | 2`: performs one round trip into ring 3 with the register file in `ctx` and returns why it came back: `0` a system call, `1` an exception, `2` an interrupt that the host has already handled. `ctx` is the kernelet's own `RawUserContext` in its heap; the host reads it before the transition and writes it after, and keeps nothing. The loop around it, the pre-run hook and the kernel-event check, stays in OSTD (kernelet build) ([User mode](virtualizing-ostd/user-mode.md)). *Checks:* `ctx` inside the window; the task has an activated address space. *Cost:* the ring transition, the same as today's.

### Devices

- `mmio_read(dev, offset, width, out)`, `mmio_write(dev, offset, width, value)`: one register access on virtual device `dev`, forwarded to `KerneletHooks::mmio_read` or `mmio_write`. *Checks:* `dev` in the device table, `offset + width ≤ reg_bytes`, `width ∈ {1, 2, 4, 8}`. *Cost:* the hook; a queue notification is where the endovisor's device model does its work, on this task, charged to this kernelet.

### Output and end of life

- `log_write(level, module, text)`: copies the text into the host's rate limiter and, if under the kernelet's limit, delivers it to `KerneletHooks::log`; otherwise drops it and counts. Formatting happened in the kernelet. *Checks:* both buffers inside the window; `text_len ≤ 1024`. *Cost:* the copy and the hook.
- `console_write(bytes, len)`: the early console, same rules.
- `exit(code) -> !`: the kernelet has finished (`power::poweroff` or `restart` in the kernel proper). Marks it `Dying` with `Exited(code)`, then terminates the calling task; the other tasks are cancelled and terminated at their next quiescent point.
- `panic(msg) -> !`: a panic in the kernelet that its own handler could not turn into an oops. Marks it `Dying` with `Panicked(msg)` and terminates the calling task. Nothing unwinds across the boundary.

## What the service half does not offer

There is no function to read or write host memory, to map anything outside the window, to allocate a frame by physical address, to disable interrupts, to send an interrupt, to change the CPU set, to load a page table that was not registered, or to call anything by address. Each of those is an *absent* item in the taxonomy, and its absence from this table is what makes the absence real at the ELF boundary (invariant I1).

## What this page decides

- **A flat function table, with the caller identified from the host's per-CPU slot.** The alternative, a context argument on every call, would let one function serve several kernelets on one stack, which nothing needs, and would put a pointer the kernelet must not forge on every crossing. The slot is written by the host alone.
- **Task records shared read-write.** The kernelet's preemption count and the host's flags could each be a service call instead; they are on every lock and every preemption point, so they are memory. The record holds nothing whose corruption by a buggy kernelet build could harm another kernelet: a wrong `preempt_count` delays that kernelet's own preemption until the tick budget kills it.
- **One worker task per kernelet for all deferred work**, fetched by `job_wait`. It keeps the host from ever calling into the entry table except at task start, which is what lets invariant I7's counter be a single bit per task.
