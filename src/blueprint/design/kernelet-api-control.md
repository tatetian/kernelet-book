# The kernelet API: control half

*Answers question 1: what API does OSTD (host build) provide so that the endovisor can manage the lifecycle of kernelets and customize their behavior?*

The control half is the module `ostd::kernelet::control`, present only in the host build. It is the whole of what the endovisor sees of a kernelet: it registers images, creates kernelets, gives them memory, CPUs and devices, starts, observes, kills and destroys them, and it supplies the hooks OSTD calls back when a kernelet's request needs the host kernel's Linux functionality. Everything on this page is host-side Rust; no kernelet ever holds a reference to any of it. Invariants enforced here: I3 (privacy), I4 (no retained reference), I6 (charged work), and the host side of I7 (termination).

## Division of labor over the window

The control half and the service half share the [window](builds-and-images.md#window) with OSTD (kernelet build), and each region has exactly one mapper:

| region | mapped by | frames from | when |
|---|---|---|---|
| the level-3 table itself | control half | host memory, charged to the kernelet's host-overhead account | `create` |
| `KW_TEXT` | control half | the kind's shared frames, 2 MiB-aligned so that they map as 2 MiB pages | `create` |
| `KW_DATA` (template and replicas) | control half | host memory, charged to the kernelet | `create` |
| `KW_SHARED` | control half | host memory, charged to the kernelet | `create` |
| `KW_HEAP`, level-3 entries and the level-2 tables | control half; the tables are reserved frames at the head of the kernelet's runs, written through the linear map | the grant | `create`, and `grant` when it raises the coverage |
| `KW_HEAP`, the initial runs' level-2 entries | control half | the grant | `create` |
| `KW_HEAP`, later runs' level-2 entries | OSTD (kernelet build), into the same reserved frames | the grant | as runs arrive |

So the host bootstraps the window's heap mappings at creation and installs level-2 tables ahead of need, and the kernelet writes only entries in frames of its own grant; the grant table and the physical-address radix the kernelet reads are host-written pages in `KW_SHARED` ([Memory](virtualizing-ostd/memory.md)). The kernelet never writes a page-table entry that lives in host memory.

## Images

An image is registered once per kind, at boot, from bytes embedded in the host image ([Builds and images](builds-and-images.md)).

```rust
pub struct ImageId(u16);

/// Parses a kernelet image, checks it, and installs it as a kind. Copies the
/// read-only segments into 2 MiB-aligned shared frames, keeps the writable segment
/// as the data template, and reads the entry table at `KW_TEXT + 4 KiB`.
pub fn register_image(name: &'static str, elf: &'static [u8]) -> Result<ImageId, ImageError>;

pub enum ImageError {
    NotElf, WrongArch, HasRelocations, HasUndefinedSymbols, SegmentOutsideWindow,
    WritableAndExecutable, EntryOutsideText, EntryTableMisplaced,
    EntryTableVersion { found: u32, expected: u32 }, BadTableBounds, SourceHashMismatch, NoMemory,
}

pub struct ImageInfo {
    pub name: &'static str,
    pub text_bytes: usize,        // shared, read-only
    pub template_bytes: usize,    // `.data` + `.bss`, copied per kernelet
    pub cpu_local_bytes: usize,   // replicated per virtual CPU
    pub entry_table_version: u32,
}
pub fn image_info(id: ImageId) -> Option<&'static ImageInfo>;
```

Registration repeats, in trusted code and on the bytes actually booted, every check of the [audit](builds-and-images.md#audit) that can be made on the ELF alone: no relocations, no undefined symbols, every segment inside `KW_TEXT` or `KW_DATA` and none both writable and executable, `e_entry` inside `KW_TEXT`, the entry table at its fixed offset with the expected size and version, the exception-table and `.cpu_local` bounds inside their segments, and the source hash equal to the host build's. The bounds check is what invariant I5 needs before the host ever jumps to an exception-table fixup. A failure is a boot-time error for that kind, not for the host.

## Identity

```rust
/// Names a kernelet for its whole life and never repeats: a slot index into a
/// fixed table and a generation, starting at 1, that the slot's reuse increments.
/// Every host table that refers to a kernelet stores this and nothing else
/// (invariant I4). `Option<KerneletId>` is 8 bytes because the generation is non-zero.
#[derive(Copy, Clone, PartialEq, Eq, Hash, Debug)]
pub struct KerneletId { pub slot: u16, pub generation: NonZeroU32 }

/// Build-time bound on live kernelets; sizes the slot table. Chosen, not measured.
pub const MAX_KERNELETS: usize = 4096;
/// A task's name inside its kernelet: an index into the kernelet's task table.
pub type TaskName = u32;
```

## Configuration

What a kernelet is given is decided before it runs and, except for memory and the CPU budget, cannot change afterward.

```rust
pub struct KerneletConfig {
    pub image: ImageId,
    /// Host CPUs this kernelet's tasks may run on. Its virtual CPU `i` is the
    /// `i`-th CPU of the set in ascending order; `num_cpus()` inside the kernelet
    /// is the set's size. Fixed for the kernelet's life. At most `MAX_VCPUS` (256).
    pub cpus: CpuSet,
    /// Memory, in 2 MiB grains: granted at creation, and the most the kernelet may
    /// take by itself. `grant` raises both.
    pub initial_grains: u32,
    pub max_grains: u32,
    pub budget: CpuBudget,
    /// The kernel command line the kernelet's kernel sees as `boot_info().kernel_cmdline`.
    pub cmdline: String,
    /// Virtual devices, in the order the kernelet's MMIO bus enumerates them.
    pub devices: Vec<DeviceDesc>,
    pub policy: KerneletPolicy,
}

pub struct CpuBudget {
    /// Relative share against other kernelets and host groups; the scheduler's unit.
    pub weight: u32,
    /// Hard cap: at most `quota_us` of CPU time per `period_us`, over all its tasks. `None` is uncapped.
    pub quota: Option<(u32 /* quota_us */, u32 /* period_us */)>,
}

/// One virtual MMIO device. The register file is served by the endovisor's
/// device model through `KerneletHooks::mmio_read` and `mmio_write`; OSTD only
/// knows the device's size and interrupt line. The kernelet's virtio MMIO
/// transport finds it in `BootArgs` ([Devices](virtualizing-ostd/devices.md)).
pub struct DeviceDesc {
    pub id: DeviceId,          // chosen by the endovisor; unique within the kernelet
    pub kind: DeviceKind,      // `VirtioMmio { device_type: u32 }` for now
    pub reg_bytes: u32,        // size of the register window, a multiple of 4 KiB
    pub irq: Virq,             // the virtual interrupt line the device raises
    pub mmio_base: u64,        // the pseudo-physical address the kernelet's bus probe finds it at
}
#[derive(Copy, Clone, PartialEq, Eq, Hash, Debug)] pub struct DeviceId(pub u16);
#[derive(Copy, Clone, PartialEq, Eq, Hash, Debug)] pub struct Virq(pub u8);   // 32..=255

pub struct KerneletPolicy {
    /// Oopses (caught panics, reported through the `oops` service call) allowed before the kernelet is killed.
    pub oops_budget: u32,
    /// Consecutive ticks a task may hold preemption off before the kernelet is killed.
    pub preempt_off_ticks: u32,
    /// Log bytes per second delivered to the hook; beyond it, records are dropped and counted.
    pub log_bytes_per_sec: u32,
    /// When the kernelet has taken `max_grains` and asks for more: consult
    /// `on_grant_exhausted` (true) or refuse at once (false).
    pub ask_before_oom: bool,
    /// Ticks per second posted to an idle kernelet's virtual CPU 0, so that its kernel's
    /// timers still fire; 0 means none ([Interrupts and time](virtualizing-ostd/interrupts-and-time.md)).
    pub idle_tick_hz: u32,
}
```

`create` validates the configuration and fails with one of:

```rust
pub enum CreateError {
    UnknownImage, NoCpus, TooManyCpus, CpuNotOnline(CpuId),
    InitialExceedsMax, ZeroMaxGrains, DuplicateDevice(DeviceId), ReservedVirq(Virq),
    RegBytesNotPageMultiple(DeviceId), TooManyDevices, CmdlineTooLong,
    SlotsExhausted, NoMemory,
}
```

## Hooks: how OSTD calls the endovisor

The endovisor customizes a kernelet's behavior by implementing one trait per kernelet and passing it at creation. The five *request* hooks (`mmio_read`, `mmio_write`, `log`, `console_write`, `on_grant_exhausted`) and `on_oops` run on the kernelet's own task, inside a service call, with the kernelet's page table active, and their time is charged to the kernelet. They must not sleep: a driver holds a spin lock across a register write as it would for real hardware, so a hook is a bounded amount of state manipulation, and anything that needs host I/O is handed to a device thread ([Devices](virtualizing-ostd/devices.md)). `on_dying` runs on whichever task caused the death: the killer's host task, or the kernelet task that called `exit` or `panic`. `on_exited` runs on a host reaper task after the last kernelet task has switched away, so that its stack is not the one being reaped. The hooks are the only path from a kernelet's requests into the host kernel's Linux functionality.

```rust
pub trait KerneletHooks: Send + Sync + 'static {
    /// A read of `width` bytes (1, 2, 4 or 8) at `offset` in device `dev`'s register file.
    fn mmio_read(&self, k: &Kernelet, dev: DeviceId, offset: u32, width: u8) -> u64;
    /// The matching write. A write to a virtio queue's notify register is where a
    /// device model walks the queue; it does so through `k.guest_memory()`.
    fn mmio_write(&self, k: &Kernelet, dev: DeviceId, offset: u32, width: u8, value: u64);

    /// A formatted log record from the kernelet's `log` macros, already rate-limited.
    fn log(&self, k: &Kernelet, level: LogLevel, module: &str, text: &str);
    /// Bytes from the kernelet's early console (`early_print!`).
    fn console_write(&self, k: &Kernelet, bytes: &[u8]);

    /// The kernelet has taken `max_grains` and asks for more, and `policy.ask_before_oom`
    /// is set. Return how many grains to add to both the grant and `max_grains`;
    /// `0` refuses, and the kernelet's allocator sees an empty grant.
    fn on_grant_exhausted(&self, k: &Kernelet) -> u32 { 0 }

    /// A task of the kernelet took an oops (a caught panic); the budget has been charged.
    fn on_oops(&self, k: &Kernelet, task: TaskName, message: &str) {}
    /// The kernelet has entered `Dying`. Called once. The endovisor must cancel every
    /// outstanding host I/O of its device models here, so that hooks in progress return
    /// and pins drain; until they do, the kernelet cannot exit.
    fn on_dying(&self, k: &Kernelet, reason: &ExitReason) {}
    /// Every task has stopped and the kernelet is `Exited`; `destroy` may now be called.
    fn on_exited(&self, k: &Kernelet, status: &ExitStatus) {}
}

#[derive(Copy, Clone, PartialEq, Eq, Debug)]
pub enum LogLevel { Emerg, Alert, Crit, Error, Warn, Notice, Info, Debug }
```

**What a hook may call.** Inside a hook, these methods of `Kernelet` are safe: `id`, `state`, `config`, `stats`, `guest_memory`, `raise_irq`, `charge_host_bytes`, `uncharge_host_bytes`, `adopt_current_task` and `disown_current_task`. A device that completes at once, a console or an entropy source, raises its interrupt from inside `mmio_write`. These are not: `grant`, `kill`, `wait_exited` and `destroy`, which either take the state word the hook's caller holds or block on the task the hook is running on.

**A hook must return in bounded time, and may not sleep.** Neither is enforced. A task inside a hook is at service-call depth one, so `kill` cannot terminate it, `wait_exited` times out, and `destroy` is never legal; a kernelet with a task stuck in a hook holds its grant until the hook returns, as a process stuck in uninterruptible sleep holds its memory. Because hooks cannot sleep, the host I/O behind a device is done by a **device thread** the endovisor runs per device, woken by the notify hook and handing completions back with `raise_irq`. `on_dying` is where the endovisor cancels those threads' outstanding I/O so that pins drain.

**Host memory a device model allocates** inside a hook, a `Vec` for a request or frames for a bounce buffer, is charged to no one by the host's allocators, which do not consult the CPU slot. The endovisor accounts for it explicitly through `charge_host_bytes`, and bounds it by the queue depths its device models accept ([Devices](virtualizing-ostd/devices.md)).

**Device threads have no process.** The host kernel's file and socket paths that need a current process (credentials, a root directory, a file-descriptor table) cannot be entered from a kernel thread. The endovisor therefore opens every host resource a device needs, a backing file, a tap device, a socket, at attach time on the kernelet runtime's process, through the [endovisor ABI](endovisor.md), and holds the resulting kernel objects; a device thread drives those objects. **[unverified]** (register A5): that the host kernel's file and socket objects can be driven by a kernel thread without a process context. If some cannot, the device thread carries a borrowed context from the runtime's process. A device thread's CPU time is charged to the kernelet it serves by adopting it into the kernelet's scheduling group:

```rust
impl Kernelet {
    /// Charges the calling host task's CPU time to this kernelet until `disown_current_task`.
    /// Used by the endovisor's device threads. Hook-safe. Fails once the kernelet is `Exited`.
    pub fn adopt_current_task(&self) -> Result<(), StateError>;
    pub fn disown_current_task(&self);
}
```

Device models need to read and write the kernelet's memory: a virtio queue lives in the kernelet's frames. The control half gives them a checked, scoped accessor rather than a mapping:

```rust
impl Kernelet {
    /// Runs `f` with a reader and writer over `len` bytes at physical address `paddr`
    /// of this kernelet's memory. Fails unless every frame of the range is in the
    /// kernelet's grant. Every grain of the range is pinned for the duration of `f`;
    /// a destroy that finds a pin does not wait but returns `Zombie`, and is retried
    /// once the pin is gone. The reader and writer go through the host's linear map
    /// and are valid only inside `f`.
    pub fn guest_memory<R>(
        &self, paddr: Paddr, len: usize,
        f: impl FnOnce(&mut VmReader<'_, Infallible>, &mut VmWriter<'_, Infallible>) -> R,
    ) -> Result<R, MemoryAccessError>;

    /// Explicit accounting of host memory a device model holds for this kernelet.
    pub fn charge_host_bytes(&self, bytes: usize) -> Result<(), LimitError>;
    pub fn uncharge_host_bytes(&self, bytes: usize);
}
pub enum MemoryAccessError { NotOwned, Destroying }
```

This is the one place outside a service call's own pointer arguments where host code touches a kernelet's memory, it is bounded by a closure, and the pin is what lets [Faults, termination, and reclamation](faults-and-reclamation.md) release frames without a use-after-release: no accessor outlives its pin, and destroy releases nothing while a pin is held.

## Lifecycle

```rust
pub struct Kernelet { /* host-side state; see below */ }

impl Kernelet {
    /// Builds a kernelet: its slot and identifier; its kernel page table (the host's
    /// with entry 500 replaced by a fresh level-3 table); the window's host-mapped
    /// regions (`KW_TEXT` from the kind's shared frames, `KW_DATA` from the template with
    /// the per-virtual-CPU replicas, `KW_SHARED` with `BootArgs`, the info page and the
    /// task records); the initial grant of `initial_grains` grains, recorded in the grant
    /// table and the owner array and listed in `BootArgs`; the device table; one worker
    /// task per virtual CPU (`run_task(1, vcpu)`) and the boot task (`_kernelet_entry`),
    /// all created but not runnable. Fails, with everything undone, on any error.
    pub fn create(config: KerneletConfig, hooks: Arc<dyn KerneletHooks>) -> Result<Arc<Kernelet>, CreateError>;

    pub fn id(&self) -> KerneletId;
    pub fn state(&self) -> KerneletState;
    pub fn config(&self) -> &KerneletConfig;

    /// `Created → Running`: the boot task and the workers become runnable. The boot
    /// task enters `_kernelet_entry` on the kernelet's kernel page table.
    pub fn start(&self) -> Result<(), StateError>;

    /// Adds `grains` to the grant and to `max_grains` as one run if it can and as several
    /// otherwise, appends them to the grant table, installs level-2 tables if needed, and
    /// posts `JOB_GRANT` so that the kernelet maps them. Legal in `Created` and `Running`.
    /// Memory only grows; a kernelet returns memory by exiting.
    pub fn grant(&self, grains: u32) -> Result<u32 /* granted */, GrantError>;

    pub fn set_budget(&self, budget: CpuBudget) -> Result<(), StateError>;

    /// Injects a virtual interrupt: sets the line's pending bit and wakes the worker
    /// of the virtual CPU the line is bound to. Idempotent while the line is pending.
    /// Legal in `Running`; hook-safe.
    pub fn raise_irq(&self, virq: Virq) -> Result<(), StateError>;

    /// Asks the kernelet to die. `Created → Exited` at once, since nothing has run.
    /// `Running → Dying`: sets `dying` on the info page and `DYING` in every task
    /// record, wakes every parked task with a cancellation, and lets each task reach
    /// its next quiescent point, where it is terminated. Idempotent in `Dying`.
    /// Returns at once.
    pub fn kill(&self, reason: KillReason) -> Result<(), StateError>;

    /// Blocks the calling host task until the kernelet is `Exited`, or until `timeout`.
    pub fn wait_exited(&self, timeout: Option<Duration>) -> Result<ExitStatus, Timeout>;

    /// Reclaims everything. `Exited → Destroying` by compare-and-swap, then waits for
    /// in-progress control operations to drain (they are short), then drains every host
    /// table that names this kernelet, unmaps the window, drops the host `Segment` that
    /// holds each run, frees the host objects, and retires the slot
    /// (`Destroyed`). If any grain is pinned by a `guest_memory` in progress, returns
    /// `Zombie` without releasing anything; the kernelet stays charged and `destroy`
    /// is retried once the pin is gone.
    pub fn destroy(&self) -> Result<ReclaimReport, DestroyError>;

    pub fn stats(&self) -> KerneletStats;
}

#[derive(Copy, Clone, PartialEq, Eq, Debug)]
pub enum KerneletState { Created, Running, Dying, Exited, Destroying, Destroyed }

pub enum KillReason {
    Requested, OopsBudget, PreemptOffTooLong, StackReserve, StackOverflow,
    /// A page fault in kernelet code with no exception-table entry ([User mode](virtualizing-ostd/user-mode.md)).
    KernelFault { addr: u64, ip: u64 },
    HostPolicy(u32),
}

pub enum ExitReason {
    /// The kernelet's kernel called `power::poweroff` or `restart`; the code it passed.
    /// `0` maps to OSTD's `ExitCode::Success`, anything else to `Failure`.
    Exited(u32),
    /// A panic that could not be caught inside the kernelet, with its message. An
    /// allocation failure the kernelet's kernel could not absorb ends here too.
    Panicked(String),
    Killed(KillReason),
}
pub struct ExitStatus { pub reason: ExitReason, pub uptime: Duration, pub cpu_time: Duration }

pub struct StateError { pub state: KerneletState }
pub enum GrantError { State(KerneletState), Limit, NoMemory }
pub enum DestroyError { NotExited(KerneletState), Zombie { pins: u32 } }
pub struct Timeout;
pub struct LimitError;

pub struct ReclaimReport {
    pub grains_released: u32,
    pub tasks_reaped: u32,
    pub roots_forgotten: u32,      // registered page-table roots
    pub host_bytes_uncharged: usize,
}

pub struct KerneletStats {
    pub grains_granted: u32,
    pub max_grains: u32,
    pub host_bytes_charged: usize,
    pub tasks: u32,
    pub cpu_time: Duration,
    pub service_calls: u64,
    pub mmio_accesses: u64,
    pub irqs_raised: u64,
    pub log_bytes: u64,
    pub log_records_dropped: u64,
    pub oopses: u32,
}
```

**The state machine.** `Created → Running → Dying → Exited → Destroying → Destroyed`, with two shortcuts: `Created → Exited` by `kill`, and `Exited → Destroying → Exited` when `destroy` returns `Zombie`. Every transition is one compare-and-swap on the state word. `start` is legal in `Created`; `grant` in `Created` and `Running`; `set_budget` and `raise_irq` in `Running`; `kill` in `Created`, `Running` and `Dying`; `destroy` in `Exited`. A service call that finds `dying` set on entry returns `-DYING` to the kernelet instead of proceeding ([service half](kernelet-api-service.md)).

**Concurrency.** Two host tasks may operate on one kernelet at once, and a host task may operate on it while its tasks run. Every `&self` operation except `destroy` increments an operation count on entry and decrements it on exit, and refuses with `StateError` if the state is `Destroying` or `Destroyed`; `destroy` moves to `Destroying` first and then waits for the count to reach zero before touching any field, so no operation runs against a kernelet being torn down. The grant table is append-only: a chunked array whose count is published with a release store after the chunk is written, so a reader that indexes below the count never sees a partial entry, and no reallocation happens under a reader. The owner array is written by `create`, `grant` and `destroy` only, under the grant table's append order. The pending-interrupt bitmap and the accounts are atomics.

**Memory growth.** A kernelet takes grains by itself through the service half's `grains_request` until it holds `max_grains`; no host decision is involved below that line, and the grains come from the host's free memory when the request is made. At `max_grains`, the request consults `on_grant_exhausted` if `ask_before_oom` is set, and otherwise returns nothing. A refused request reaches the kernel proper as `Error::NoMemory` from `FrameAllocOptions`, and from there the kernelet's own out-of-memory handling applies, `ENOMEM` to the process or the kernelet's OOM killer ([Memory](virtualizing-ostd/memory.md)). The host never kills a kernelet for memory; a kernelet whose kernel cannot absorb an allocation failure panics, and that is `Panicked` ([Faults, termination, and reclamation](faults-and-reclamation.md)).

## What the host keeps per kernelet

The fields of `Kernelet`, listed so that the destroy sequence can be checked against them and so that invariant I4 can be reviewed: every field is host memory, and the only window addresses among them are the mapping records that destroy unmaps.

| field | what it holds | who writes it |
|---|---|---|
| `id`, `state`, `ops_in_progress` | identity; the state word; the operation count | control half |
| `image`, `config`, `hooks` | the kind, the configuration, the endovisor's hooks | creation |
| `kernel_pt`, `window_l3` | the kernelet's kernel page table root and its private level-3 table for entry 500; the host's mappings under it (`KW_TEXT`, `KW_DATA`, `KW_SHARED`) | creation |
| `grant` | the grant table: each run's physical base, first slot, length and reserved level-2 frames, mirrored read-only into `KW_SHARED`, plus each run's pin count and its host `Segment`; append-only, chunked | `create`, `grant`, `grains_request`; pins by `guest_memory` |
| `roots` | the user page-table roots the kernelet has registered | the service half |
| `tasks` | the host tasks that are this kernelet's, by name; the boot task and the workers among them, with each worker's virtual CPU | the service half's spawn and exit |
| `devices`, `virq_pending: [AtomicU64; 4]` | the device table and the pending-interrupt bitmap | creation; `raise_irq`; the workers clear bits through `irq_ack` |
| `shared` | the frames mapped read-only (`BootArgs`, the info page) and read-write (the task records) into `KW_SHARED` | creation; the scheduler writes task records |
| `accounts` | the counters behind `stats()`, the host-bytes charge, and the CPU quota's period accounting | the service half, the scheduler, the hooks |
| `exit: Once<ExitStatus>`, `exit_waiters: WaitQueue` | the outcome, and who is waiting for it | the reaper; `wait_exited` |

Two host-wide tables complete the picture. The **slot table** maps `KerneletId::slot` to the `Arc<Kernelet>` and the current generation, and is how the service half finds the caller's kernelet from the CPU slot in constant time; it drops its `Arc` at `Destroyed`. The **owner array** has one `Option<KerneletId>`, 8 bytes, per 2 MiB grain of physical memory, written when a grain is granted and cleared when it is released; it is what `guest_memory` and the service half's ownership checks read, and its size is physical memory divided by 2 MiB times 8 bytes: 4 MiB for a 1 TiB machine.

**Grains are 2 MiB-aligned.** The host allocates a grain with a new host-build entry point, `alloc_segment_aligned`, since `FrameAllocOptions::alloc_segment_with` asks its allocator for page alignment only (measured on the tree, `ostd/src/mm/frame/allocator.rs`). Alignment lets the kernelet map a grain as one 2 MiB page and lets the owner array be indexed by `paddr >> 21`. Its cost is fragmentation in the host's frame allocator, which the Evaluation chapter will measure; where an aligned grain cannot be had, `grant` fails with `NoMemory` rather than falling back to unaligned grains.

## Costs

Per kernelet, `create` costs, in host memory charged to the kernelet: one level-3 table; one level-2 table for `KW_TEXT`, whose 2 MiB pages need no level-1 tables (about seven entries for the tree's 14 MiB debug image, measured with `size -A`); one level-2 and one or two level-1 tables for `KW_DATA` and `KW_SHARED`; the data template copy, under 128 KiB *estimated* ([Builds and images](builds-and-images.md)); the per-virtual-CPU replicas at about 2 KiB each, measured on the tree; the shared pages, including the grant table and the radix leaves; and one task per virtual CPU plus the boot task, each with a 512 KiB kernel stack and four guard pages of vmalloc (measured on the tree: `DEFAULT_STACK_SIZE_IN_PAGES = 128`, `ostd/src/task/kernel_stack.rs`), which is the largest fixed item. The host-side `Kernelet` object is a few kilobytes (*estimated*). Per run: one `alloc_segment_aligned`, one grant-table append, the owner-array and radix writes, and, after boot, one `JOB_GRANT` wakeup; at creation, and whenever the coverage grows, one level-3 entry and one reserved level-2 frame per 512 slots. `raise_irq` is one atomic or and one wakeup. `kill` is one store to the info page plus one store and one wakeup per task. `destroy` is linear in grains, tasks, roots and devices; its cost is the drain list of [Faults, termination, and reclamation](faults-and-reclamation.md).

Per hook call, the endovisor pays whatever its device model does; the control half adds, in `guest_memory`, one owner-array read and one pin increment and decrement per grain touched.

## What this page decides

- **Hooks are a trait object per kernelet, called synchronously on the kernelet's task** (register D5). The alternative, a queue of requests served by an endovisor thread, would keep host Linux code off the kernelet's task and its stack, but it turns every device register access into a cross-task round trip with a wakeup; the booted prototype measured a cross-domain round trip at 9.4 µs where a call into its virtualization layer cost 35 cycles against 34 for a plain call (see the Paper's Evaluation section). Synchronous hooks keep a register access at function-call cost; the price is that the hook runs on a stack shared with kernelet frames below it, must respect the stack reserve of the service half, cannot sleep, and cannot be terminated while it runs. What needs host I/O goes to a device thread at the cost of one wakeup per queue notification, which is what a real device's DMA engine costs a driver too (register D12).
- **Memory only grows** (register A1). Reclaiming memory from a running kernelet needs its cooperation, a balloon, and a story for pages the kernelet has mapped to user space; none of that is needed to give every agent a sandbox that exits when it is done.
- **Device models live in the endovisor, not in OSTD** (register D6). OSTD knows a device only as a register window and an interrupt line, because a device model over host files and sockets is Linux functionality, written in the safe-Rust kernel proper, not in OSTD's `unsafe`-bearing framework.
- **The kernelet maps its own heap and metadata** (register D10). The host could map every grain into `KW_HEAP` in `grant`, which would keep all page-table writes in the host; but every kernelet already writes leaf entries for its user page tables, the window's sub-tables are frames from its own grant that destroy releases wholesale, and keeping the host out of `KW_HEAP` removes a service call per grain and a host write into a per-kernelet structure.
