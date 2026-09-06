# The kernelet API: service half

*Answers question 3: what API does OSTD (host build) expose to OSTD (kernelet build), and how does a call cross from the kernelet image into the host?*

The service half is what a kernelet gets from the host at run time. Its wire form, the **image ABI**, is two tables of `extern "C"` function pointers and a few shared pages; its implementation is the module `ostd::kernelet::service` in the host build. Every virtualized item on the [taxonomy](virtualizing-ostd/index.md) bottoms out in one of the functions on this page, and every function here is specified with its signature, what it checks, and what it costs. Invariants enforced here: I1 (reach), the service side of I2 (ownership), I4 (no retained reference), I5 (no closure crosses), I6 (charged work) and the counter behind I7 (termination).

The tables and the shared-page layouts are defined once, in a module compiled into both builds, `ostd::kernelet::abi`, with no `cfg` inside it, so the two sides cannot disagree on a field. Every error code and constant below is a named value in that module.

## How the host knows who is calling

A service function takes no kernelet or task argument. The host learns both from its own per-CPU area, which the scheduler writes on every switch to or from a kernelet task (a 16-byte store per switch):

```rust
// ostd::kernelet::abi — read by both builds; written only by the host scheduler.
#[repr(C)]
pub struct CpuSlot {
    /// The kernelet whose task is running on this CPU, or `NONE`.
    pub kernelet: u16,        // slot index
    pub vcpu: u16,            // this CPU's index in the kernelet's CPU set
    pub task: u32,            // the running task's name, `TaskName`
    pub generation: u32,      // the kernelet's generation, so a stale slot is detected
    pub _reserved: u32,
}
```

The slot lives in the host's per-CPU storage at an offset published in `BootArgs::cpu_slot_gs_offset`; OSTD (kernelet build) reads it with one GS-relative load, the same instruction OSTD's own `Task::current` uses today. Reading `task` needs no preemption guard: a task that migrates reads its own name on the new CPU. Reading `vcpu` requires preemption disabled, as every per-CPU read does, and the host's kernel-mode preemption honors the kernelet's preemption count ([Tasks](virtualizing-ostd/tasks.md)).

A **task name** is a `u32` of two halves, `index:16 | generation:16`. The index selects the task's record; the generation distinguishes a reuse of the index, so that a late `task_unpark` with a stale name fails with `-INVALID` instead of waking a stranger. A kernelet may have at most `max_tasks` (65,536) live tasks; retired indices are reused with the next generation. Names, not pointers, are what cross (invariant I4).

## Host-private per-task state

The state on which termination depends is host memory a kernelet cannot address. Each host task that belongs to a kernelet carries:

```rust
// Inside the host's `Task`, only for kernelet tasks. Host memory.
pub(crate) struct KerneletTaskState {
    pub kernelet: KerneletId,
    pub name: TaskName,
    /// 0 while in kernelet code, 1 while inside a service call. Written by the service
    /// prologue and epilogue with `Release`; read by the kill and tick paths with `Acquire`.
    /// This is invariant I7's counter, and it is host-private so that no kernelet can
    /// hold it at 1.
    pub service_depth: AtomicU32,
    /// Host-owned flags: NEED_RESCHED, DYING, CANCEL_PARK, PARK_TOKEN.
    pub flags: AtomicU32,
    /// The user page-table root the task last activated; the scheduler restores it.
    pub root: AtomicU64,
    /// User FS and GS bases and an XSAVE area, saved on an involuntary switch away from
    /// kernelet code and restored on the way back ([Tasks](virtualizing-ostd/tasks.md)).
    pub tls_fpu: SavedUserState,
    /// The trampoline's stack pointer, to which termination resets the stack.
    pub entry_sp: u64,
}
```

## The shared pages

The regions of `KW_SHARED` are host frames mapped into the kernelet's window ([Builds and images](builds-and-images.md#window)); the host writes them through its linear-map alias, never through a window address (invariant I4).

**The boot arguments**, read-only, at `KW_SHARED + 0`, written once at creation:

```rust
#[repr(C)]
pub struct BootArgs {
    pub size: u32, pub version: u32,
    pub kernelet: u16, pub generation: u32,
    pub num_vcpus: u16,
    /// Host CPU of each virtual CPU, in order. MAX_VCPUS = 256.
    pub vcpu_host_cpu: [u16; MAX_VCPUS],
    pub cpu_slot_gs_offset: u32,
    pub cpu_local_replica_bytes: u32,
    /// The kernelet's kernel page table: its root, the physical address of its
    /// window level-3 table, and the 256 kernel-half top-level entries that every
    /// user page table the kernelet creates must copy.
    pub kernel_pt_root: u64, pub window_l3: u64,
    pub kernel_half_entries: [u64; 256],
    /// Memory: the most grains the kernelet may take, and the offsets, from `KW_SHARED`,
    /// of the host-written grant table (an array of `RunDesc`, its length in the info page)
    /// and the physical-grain-to-slot radix ([Memory](virtualizing-ostd/memory.md)).
    pub max_grains: u32, pub grant_table: u32, pub grain_radix: u32,
    /// Devices: `num_devices` entries of `DeviceEntry` follow the struct.
    pub num_devices: u16,
    /// Offsets, from `KW_SHARED`, of the clock page, the info page and the task-record array.
    pub clock_page: u32, pub info_page: u32, pub task_records: u32, pub max_tasks: u32,
    pub tsc_freq_hz: u64,
    /// The command line follows the devices: `cmdline_len` bytes.
    pub cmdline_len: u32,
}
#[repr(C)] pub struct RunDesc { pub paddr: u64, pub first_slot: u32, pub grains: u32, pub l2_frames: u32, pub _pad: u32 }
#[repr(C)] pub struct DeviceEntry { pub id: u16, pub kind: u16, pub irq: u8, pub _pad: u8, pub vcpu: u16, pub reg_bytes: u32, pub device_type: u32, pub mmio_base: u64 }
```

**The clock page**, read-only, one page, shared by every kernelet on the machine: the host tick writes it once, not once per kernelet.

```rust
#[repr(C)]
pub struct ClockPage {
    /// The host's tick counter; `Jiffies::elapsed()` in the kernelet reads this.
    pub jiffies: AtomicU64,
    /// Monotonic nanoseconds since host boot.
    pub monotonic_ns: AtomicU64,
}
```

**The info page**, read-only to the kernelet, one page per kernelet:

```rust
#[repr(C)]
pub struct InfoPage {
    /// Set once by `kill`, `exit` or `panic`; every service call after it fails with `-DYING`.
    pub dying: AtomicU32,
    /// The published length of the grant table: runs the kernelet may read and map.
    pub runs: AtomicU32,
}
```

**The task records**, read-write, `max_tasks` records of 64 bytes at `KW_SHARED + task_records`, indexed by the task name's index half. This is the only shared page a kernelet writes, and nothing on it can harm another kernelet or block a kill: a corrupted `preempt_count` delays only that kernelet's own preemption until the tick budget kills it; a corrupted mirror only blinds the kernelet to its own state.

```rust
#[repr(C, align(64))]
pub struct TaskRecord {
    /// Written by the kernelet: its preemption-disable count for this task. Read by the
    /// host's kernel-mode preemption point to decide whether the task may be switched out.
    pub preempt_count: AtomicU32,
    /// A read-only mirror, for the kernelet, of the host-private flags NEED_RESCHED,
    /// DYING and CANCEL_PARK; the host writes it whenever it writes the private copy.
    pub flags_mirror: AtomicU32,
    /// Written by the host's page-fault handler before it jumps to an exception-table
    /// recovery address: the faulting address and error code, for the kernelet's retry
    /// loop ([User mode](virtualizing-ostd/user-mode.md)).
    pub fault_addr: AtomicU64, pub fault_code: AtomicU32,
    pub _reserved: [u32; 11],
}
```

## The entry table

Read by the host from `KW_TEXT + 4 KiB` of the kernelet image at registration ([Builds and images](builds-and-images.md#entry)). The host executes kernelet code in exactly two ways: the boot task's trampoline calls `_kernelet_entry`, the ELF entry point, once; every other task's trampoline calls `run_task`. Both at service-call depth zero, on a fresh task.

```rust
#[repr(C)]
pub struct EntryTable {
    pub size: u32, pub version: u32,
    /// The body of a spawned task. Called by the host's task trampoline on a fresh task,
    /// on the kernelet's kernel page table, with `entry` and `arg` from the spawn.
    /// `entry == 1` is reserved: it is the worker body, and `arg` is its virtual CPU;
    /// the host spawns one at creation per virtual CPU. Never returns: it ends with `task_exit`.
    pub run_task: extern "C" fn(entry: u32, arg: u64) -> !,
    /// Bounds of the image's exception table, for kernel-mode faults in user copies
    /// ([User mode](virtualizing-ostd/user-mode.md)). Both inside `KW_TEXT`.
    pub ex_table_start: u64, pub ex_table_end: u64,
    /// Bounds of the image's `.cpu_local` section, replicated per virtual CPU. Both inside `KW_DATA`.
    pub cpu_local_start: u64, pub cpu_local_end: u64,
    /// Hash of the OSTD source tree and toolchain; must equal the host build's.
    pub source_hash: [u8; 32],
}
```

Every entry index above 1 names a closure the kernelet stored in its own heap before calling `task_spawn` ([Tasks](virtualizing-ostd/tasks.md)); the host never sees the closure, only the index (invariant I5).

## The service table

```rust
#[repr(C)]
pub struct ServiceTable {
    pub size: u32, pub version: u32,

    // Memory
    pub grains_request: extern "C" fn(count: u32, contiguous: u32) -> i32,
    pub pt_root_register: extern "C" fn(root_paddr: u64) -> i32,
    pub pt_root_unregister: extern "C" fn(root_paddr: u64) -> i32,
    pub pt_activate: extern "C" fn(root_paddr: u64) -> i32,
    pub tlb_shootdown: extern "C" fn(root_paddr: u64, start: u64, len: u64) -> i32,

    // Tasks
    pub task_spawn: extern "C" fn(entry: u32, arg: u64, vcpus: *const [u64; 4], prio: u32, flags: u32) -> i64,
    pub task_exit: extern "C" fn() -> !,
    pub task_destroy: extern "C" fn(name: u32) -> i32,
    pub task_yield: extern "C" fn(),
    pub task_park: extern "C" fn() -> i32,
    pub task_unpark: extern "C" fn(name: u32) -> i32,
    pub task_set_prio: extern "C" fn(name: u32, prio: u32) -> i32,
    pub task_set_vcpus: extern "C" fn(name: u32, vcpus: *const [u64; 4]) -> i32,

    // Jobs and time
    pub job_wait: extern "C" fn(out: *mut JobDesc) -> i32,
    pub tick_enable: extern "C" fn(vcpu: u32, enable: u32) -> i32,
    pub timer_arm: extern "C" fn(vcpu: u32, deadline_ns: u64) -> i32,

    // User mode
    pub user_run: extern "C" fn(ctx: *mut RawUserContext) -> i32,

    // Devices
    pub mmio_read: extern "C" fn(dev: u16, offset: u32, width: u8, out: *mut u64) -> i32,
    pub mmio_write: extern "C" fn(dev: u16, offset: u32, width: u8, value: u64) -> i32,

    // Output, faults, and end of life
    pub log_write: extern "C" fn(level: u8, module: *const u8, module_len: u32, text: *const u8, text_len: u32) -> i32,
    pub console_write: extern "C" fn(bytes: *const u8, len: u32) -> i32,
    pub oops: extern "C" fn(msg: *const u8, len: u32) -> i32,
    pub exit: extern "C" fn(code: u32) -> !,
    pub panic: extern "C" fn(msg: *const u8, len: u32) -> !,
}

#[repr(C)]
pub struct JobDesc { pub kind: u32, pub arg: u32, pub arg2: u64 }
// JOB_VIRQ: arg = the line. JOB_TICK: arg = the task the host's tick found in the CPU slot on this
// virtual CPU's host CPU (`TASK_NONE` if none), arg2 = the number of host ticks since the last
// delivery (low 32 bits) and the sampled privilege level (bit 32: user), so that the kernel
// proper's tick accounting charges the right thread once per tick ([Interrupts and time](virtualizing-ostd/interrupts-and-time.md)).
pub const JOB_VIRQ: u32 = 1; pub const JOB_TICK: u32 = 2; pub const JOB_GRANT: u32 = 3;

// Error codes: negative return values.
pub const DYING: i32 = 1; pub const NOT_OWNED: i32 = 2; pub const INVALID: i32 = 3;
pub const LIMIT: i32 = 4; pub const STATE: i32 = 5; pub const CANCEL: i32 = 6;

// `task_spawn` flags.
pub const SPAWN_SUSPENDED: u32 = 1;   // created but not runnable until `task_unpark`
pub const SPAWN_IDLE: u32 = 2;        // an idle task: runs only when its virtual CPU has no other runnable task of the kernelet,
                                      // and is unparked once each time that becomes true
```

Twenty-five functions. Return values are `0` or a positive count on success and `-code` on failure: `-DYING` (the kernelet was killed), `-NOT_OWNED` (a physical address outside the grant), `-INVALID` (a bad name, index, width or pointer), `-LIMIT` (a quota or `max_grains` reached), `-STATE` (the call is not legal now, including a sleeping call with preemption disabled), `-CANCEL` (a park cut short by a kill).

**Pointer arguments.** A pointer the host writes through (`out`, `ctx`) must lie in `KW_DATA`, in `KW_HEAP`, or in the calling task's own kernel stack (the kernel proper keeps its `UserMode` as a local of the task's entry closure; checked on the tree: `kernel/core/src/thread/task.rs`), and be aligned to its pointee; a pointer the host only reads (`module`, `text`, `bytes`, `msg`, `vcpus`) may also lie in `KW_TEXT` or `KW_SHARED`. The host checks the range before touching it, since a write to a read-only window page would fault in ring 0. Every pointer is used only during the call; the host copies what it needs and keeps no pointer afterward (invariant I4). This is the one class of host access to a kernelet's memory besides `guest_memory` on the control half, and both are bounded by a call.

### The prologue and epilogue every function shares

```rust
// ostd::kernelet::service, host build; the wrapper each table entry points at.
fn enter(may_sleep: bool, exempt_from_dying: bool) -> Result<Entered, i32> {
    let slot = cpu_slot();                                        // one GS-relative load
    let k = slot_table().get(slot.kernelet, slot.generation).ok_or(-INVALID)?;
    let st = current_task().kernelet_state();                     // host-private
    if !exempt_from_dying && k.info.dying.load(Acquire) != 0 { return Err(-DYING); }
    if may_sleep && k.task_record(st.name).preempt_count.load(Relaxed) != 0 { return Err(-STATE); }
    if stack_below_reserve() { k.kill(KillReason::StackReserve); return Err(-DYING); }
    st.service_depth.store(1, Release);                           // invariant I7: now in host code
    k.accounts.service_calls.fetch_add(1, Relaxed);               // invariant I6
    Ok(Entered { k, st })
}
fn leave(e: Entered) {
    e.st.service_depth.store(0, Release);
    if e.k.info.dying.load(Acquire) != 0 { terminate_current_task(e.st); }   // a quiescent point
}
```

The depth is stored only after every check has passed, so no error return leaves it at one; the stores are `Release` and the kill path's loads `Acquire`, so a remote observer that sees depth zero also sees every host lock the task released before it. `exit`, `panic`, `task_exit` and `task_park` are exempt from the dying check, since a dying kernelet must still be able to end its tasks and a park must return `-CANCEL`; `task_park` and `job_wait` are the calls that sleep, and they are refused with `-STATE` under a nonzero preemption count, which mirrors OSTD's own `might_sleep` assertion. The stack check compares the current stack pointer with the task's stack base plus `STACK_RESERVE`, 64 KiB *estimated* (register A3); a task found below the reserve kills its kernelet, not just itself, because its kernelet-side locks would otherwise stay held. *Estimated cost of prologue and epilogue:* one GS load, one slot-table index, two atomic stores, four loads and three compares, about 25 cycles, on top of the indirect call; a bare crossing was measured on the booted prototype at 35 cycles against 34 for a plain call, without any prologue.

**A gap this does not close.** A stack overflow in *kernelet* code, between service calls, hits the guard page; on the tree the double-fault handler exists but has no interrupt-stack-table stack of its own (checked on the tree, `ostd/src/arch/x86/trap`), so the fault has no stack to be taken on and the machine resets. The host build gives the double-fault vector an IST stack and a handler that, if the faulting instruction lies in `KW_TEXT` and the current task is at depth zero, kills that kernelet with `KillReason::StackOverflow` and switches away; if the fault is anywhere else, it halts the machine as today. **[unverified]** (register A6): that a kernelet-side overflow is always caught at depth zero with a recoverable state.

### Memory

- `grains_request(count, contiguous)`: asks for more memory now, `count` grains, as one physically contiguous run if `contiguous` is set. Grants at once, from the host's free memory, up to what `max_grains` allows; at `max_grains`, consults `KerneletHooks::on_grant_exhausted` if the policy allows, which may raise the limit. Appends the run to the host-written grant table, fills the radix, installs level-2 tables if the run raises the installed coverage, and publishes the new length in the info page before returning the number granted, possibly `0`; the kernelet maps the run itself ([Memory](virtualizing-ostd/memory.md)). *Cost:* one aligned segment allocation, the table and radix writes, or the hook.
- `pt_root_register(root)`, `pt_root_unregister(root)`: the kernelet built a user page table whose root frame is `root`; the host records it so that `pt_activate` and the scheduler accept it, and so that destroy can find every root. Unregistering a root that any task has recorded as its address space, or that is active on any CPU, fails with `-STATE`; a successful unregister invalidates the root's translations on every CPU it was active on before returning. *Checks:* `root` in the grant and not already registered. *Cost:* one owner-array read, one insertion in the kernelet's root set; on unregister, a shootdown.
- `pt_activate(root)`: writes CR3 with `root` for the current task and records `root` in the task's host-private state, so that the host's `switch_to_task` restores it on every switch to this task and records the CPU in the root's active set; when the host switches from a kernelet task to a host task it also clears its own `ACTIVATED_VM_SPACE` cache, so that the host thread's post-schedule handler re-activates its space rather than trusting a stale pointer (checked on the tree: `VmSpace::activate` early-returns when the cache matches). *Checks:* `root` registered. *Cost:* the CR3 write and, since window mappings are not Global, the loss of the window's translations.
- `tlb_shootdown(root, start, len)`: invalidates `[start, start+len)` on every host CPU in `root`'s active set, by inter-processor call, and waits; `root == 0` means every root of this kernelet, which is what a change to the window's own mappings needs, since those are shared by every root. A kernelet cannot send interrupts (absent `smp`), so this is how its `TlbFlusher` completes. *Checks:* `root` registered or zero; the range inside the user half or the window. *Cost:* one IPI per target CPU plus the wait; the target set is bounded by the kernelet's CPU set.

The window's own level-2 tables under `KW_HEAP` are written by OSTD (kernelet build) with frames from its grant, so mapping a grain into `KW_HEAP` needs no service call ([Memory](virtualizing-ostd/memory.md)). The host owns only the level-3 table and its mappings of `KW_TEXT`, `KW_DATA` and `KW_SHARED`.

### Tasks

- `task_spawn(entry, arg, vcpus, prio, flags) -> name`: creates a host task whose body is the trampoline that calls `EntryTable::run_task(entry, arg)` on the kernelet's kernel page table, with a fresh 512 KiB kernel stack (measured on the tree), in the kernelet's scheduling group, with affinity the host CPUs of the virtual-CPU set `*vcpus`, and makes it runnable unless `SPAWN_SUSPENDED`. `SPAWN_IDLE` marks an idle task ([Tasks](virtualizing-ostd/tasks.md)). *Checks:* `entry > 1`; the task limit; `*vcpus` a nonempty subset of the CPU set. *Cost:* a kernel stack and a task object, as `TaskOptions::spawn` today, plus one record initialization.
- `task_exit() -> !`: the current task ends. The host reaps the task object and its stack after switching away; the index is retired and its generation advanced. No kernelet destructor runs on the host's behalf.
- `task_destroy(name)`: ends a task that was spawned `SPAWN_SUSPENDED` and never unparked, freeing its stack; `-STATE` if it has ever run. *Cost:* the reap.
- `task_yield()`: the current task yields within its group.
- `task_park() -> 0 | -CANCEL`: parks the current task until `task_unpark(name)` or a cancellation. A park token is remembered: an unpark that arrives while the task is running sets `PARK_TOKEN`, and the next park consumes it and returns at once, so no wakeup is lost between a wait queue's enqueue and its park, which is the rule OSTD's own `park_current(has_unparked)` enforces today. A park that finds `CANCEL_PARK` set, or is interrupted by `kill`, returns `-CANCEL`; the epilogue then terminates the task.
- `task_unpark(name)`: makes the named task runnable if parked, or sets its token if running. *Checks:* the name's index and generation are this kernelet's and live. *Cost:* the scheduler's enqueue.
- `task_set_prio(name, prio)`, `task_set_vcpus(name, vcpus)`: the kernelet's say over its own tasks, within its group; the host scheduler decides across groups.

### Jobs and time

- `job_wait(out) -> 0`: parks the calling task, which must be a worker, until a job for its virtual CPU is posted, then writes the job into `out`. Jobs are: a virtual interrupt (`JOB_VIRQ`, with the line number), a timer tick (`JOB_TICK`, with the interrupted task and the count of ticks coalesced), or a new grant to read from the grant table (`JOB_GRANT`). Delivery is edge-triggered: the host clears a line's pending bit, or the virtual CPU's tick bit and count, when it hands the job over, so a `raise_irq` that arrives while the handler runs becomes the next job rather than being lost; a line raised twice before delivery is one job, and ticks are coalesced with their count. A kill does not return from `job_wait`: the parked worker is terminated in the epilogue like any parked task. *Checks:* the caller is a worker. *Cost:* a park and an unpark per job; the delivery latency of a virtual interrupt is therefore a wakeup, which the Evaluation chapter will measure.
- `tick_enable(vcpu, enable)`: turns the timer tick for one virtual CPU on or off; ticks are on at `start`, and this call exists for the tickless extension. While on, the host posts `JOB_TICK` to that virtual CPU's worker at `TIMER_FREQ` (1000 Hz, on the tree) after any tick during which a task of the kernelet other than a worker delivering a tick ran on that virtual CPU's host CPU, and at the kernelet's idle rate on virtual CPU 0 otherwise ([Interrupts and time](virtualizing-ostd/interrupts-and-time.md)). *Cost:* one worker wakeup per millisecond per busy virtual CPU.
- `timer_arm(vcpu, deadline_ns)`: a one-shot: post `JOB_TICK` to the virtual CPU's worker at the first host tick at or after `deadline_ns` on the host's monotonic clock, or at once if past; a second call replaces the virtual CPU's deadline.

### User mode

- `user_run(ctx) -> 0 | 1 | 2`: performs one round trip into ring 3 with the register file in `ctx` and returns why it came back: `0` a system call, `1` an exception, `2` an interrupt that the host has already handled. `ctx` is a `RawUserContext` in the kernelet's heap, `#[repr(C)]` and defined in `ostd::kernelet::abi` with the general registers, the instruction and stack pointers, the flags, and the trap number and error code the transition fills in, layout-shared with the trap module's own type; the host reads it before the transition and writes it after, and keeps nothing. The kernelet's `execute` loop runs with its preemption count raised from the pre-run hook through this call, so that the FS and GS bases and the FPU state the hook loaded into the CPU are still there when the host switches to ring 3 under its own interrupt guard ([User mode](virtualizing-ostd/user-mode.md)). *Checks:* `ctx` writable and aligned; the task has an activated address space. *Cost:* the ring transition, as today.

### Devices

- `mmio_read(dev, offset, width, out)`, `mmio_write(dev, offset, width, value)`: one register access on virtual device `dev`, forwarded to `KerneletHooks::mmio_read` or `mmio_write`. The hooks must not sleep, because a driver holds a spin lock across a register write as it would for real hardware; a notify write hands the queue's work to the endovisor's device thread ([Devices](virtualizing-ostd/devices.md)). *Checks:* `dev` in the device table, `offset + width ≤ reg_bytes`, `width ∈ {1, 2, 4, 8}`. *Cost:* the hook; for a notify, one wakeup of the device thread.

### Output, faults, and end of life

- `log_write(level, module, text)`: copies the text into the host's rate limiter and, if under the kernelet's limit, delivers it to `KerneletHooks::log`; otherwise drops it and counts. Formatting happened in the kernelet. *Checks:* both buffers readable; `text_len ≤ 1024`. *Cost:* the copy and the hook.
- `console_write(bytes, len)`: the early console, same rules.
- `oops(msg, len) -> 0 | -DYING`: a task of the kernelet caught a panic and continues. The host charges the oops budget, calls `KerneletHooks::on_oops`, and, at the budget, kills the kernelet with `KillReason::OopsBudget`, which the epilogue then enforces.
- `exit(code) -> !`: the kernelet has finished (`power::poweroff` or `restart` in the kernel proper). Sets `dying`, records `Exited(code)`, calls `on_dying`, then terminates the calling task; the other tasks are cancelled and terminated at their next quiescent point.
- `panic(msg) -> !`: a panic in the kernelet that its own handler could not turn into an oops, or an allocation failure the kernel could not absorb. Sets `dying`, records `Panicked(msg)`, calls `on_dying`, and terminates the calling task. Nothing unwinds across the boundary.

## What the service half does not offer

There is no function to read or write host memory, to map anything outside the window, to allocate a frame by physical address, to disable interrupts, to send an interrupt, to change the CPU set, to load a page table that was not registered, or to call anything by address. Each of those is an *absent* item in the taxonomy, and its absence from this table is what makes the absence real at the ELF boundary (invariant I1).

## What this page decides

- **A flat function table, with the caller identified from the host's per-CPU slot** (register D7).
- **Task records shared read-write carry only the preemption count and a read-only mirror of the flags** (register D8, revised). The termination counter and the host's flags are host-private, so a kernelet cannot make itself unkillable; what it can corrupt harms only itself.
- **One worker per virtual CPU** (register D11), fetching all deferred work by `job_wait`; the host never enters the entry table except at task start, which is what lets invariant I7's counter be a single bit per task. Per-virtual-CPU workers are what let the kernel proper's per-CPU tick and bottom-half code run on the virtual CPU it believes it is on.
- **Hooks do not sleep** (register D12). Device register accesses happen under drivers' spin locks; the endovisor's device models therefore do their host I/O on device threads that a notify wakes, and a hook is a bounded amount of state manipulation.
