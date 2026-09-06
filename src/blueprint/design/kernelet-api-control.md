# The kernelet API: control half

*Answers question 1: what API does OSTD (host build) provide so that the endovisor can manage the lifecycle of kernelets and customize their behavior?*

The control half is the module `ostd::kernelet::control`, present only in the host build. It is the whole of what the endovisor sees of a kernelet: it registers images, creates kernelets, gives them memory, CPUs and devices, starts, observes, kills and destroys them, and it supplies the hooks OSTD calls back when a kernelet's request needs the host kernel's Linux functionality. Everything on this page is host-side Rust; no kernelet ever holds a reference to any of it. Invariants enforced here: I3 (privacy), I4 (no retained reference), I6 (charged work), and the host side of I7 (termination).

## Images

An image is registered once per kind, at boot, from bytes embedded in the host image ([Builds and images](builds-and-images.md)).

```rust
pub struct ImageId(u16);

/// Parses a kernelet image, checks it, and installs it as a kind.
/// Copies the read-only segments into shared frames, keeps the writable
/// segment as the data template, and reads `KERNELET_ENTRY_TABLE`.
pub fn register_image(name: &'static str, elf: &'static [u8]) -> Result<ImageId, ImageError>;

pub enum ImageError {
    NotElf, WrongArch, HasRelocations, HasUndefinedSymbols, SegmentOutsideWindow,
    WritableAndExecutable, EntryTableMissing, EntryTableVersion { found: u32, expected: u32 },
    SourceHashMismatch, NoMemory,
}

pub struct ImageInfo {
    pub name: &'static str,
    pub text_frames: usize,       // shared, read-only
    pub template_bytes: usize,    // `.data` + `.bss`, copied per kernelet
    pub cpu_local_bytes: usize,   // replicated per virtual CPU
    pub entry_table_version: u32,
}
pub fn image_info(id: ImageId) -> Option<&'static ImageInfo>;
```

Registration repeats, in trusted code and on the bytes actually booted, the checks the build ran on the file: no relocations, no undefined symbols, every segment inside `KW_TEXT` or `KW_DATA`, no segment both writable and executable, and a source hash equal to the host build's. A failure is a boot-time error for that kind, not for the host.

## Identity

```rust
/// Names a kernelet for its whole life and never repeats:
/// a slot index into a fixed table and a generation that the slot's
/// reuse increments. Every host table that refers to a kernelet stores
/// this and nothing else (invariant I4).
#[derive(Copy, Clone, PartialEq, Eq, Hash, Debug)]
pub struct KerneletId { pub slot: u16, pub generation: u32 }

/// Build-time bound on live kernelets; sizes the slot table and the owner array.
pub const MAX_KERNELETS: usize = 4096;
```

## Configuration

What a kernelet is given is decided before it runs and, except for memory and the CPU budget, cannot change afterward.

```rust
pub struct KerneletConfig {
    pub image: ImageId,
    /// Host CPUs this kernelet's tasks may run on. Its virtual CPU `i` is the
    /// `i`-th CPU of the set in ascending order; `num_cpus()` inside the kernelet
    /// is the set's size. Fixed for the kernelet's life.
    pub cpus: CpuSet,
    /// Memory, in 2 MiB grains: granted at creation, and the most it may ever hold.
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
    pub kind: DeviceKind,      // VirtioMmio { device_type: u32 } for now
    pub reg_bytes: u32,        // size of the register window, a multiple of 4 KiB
    pub irq: Virq,             // the virtual interrupt line the device raises
}
#[derive(Copy, Clone, PartialEq, Eq, Hash, Debug)]
pub struct DeviceId(pub u16);
#[derive(Copy, Clone, PartialEq, Eq, Hash, Debug)]
pub struct Virq(pub u8);        // 32..=255; below 32 is reserved

pub struct KerneletPolicy {
    /// Oopses (caught panics) allowed before the kernelet is killed.
    pub oops_budget: u32,
    /// Consecutive ticks a task may hold preemption off before the kernelet is killed.
    pub preempt_off_ticks: u32,
    /// Log bytes per second delivered to the hook; beyond it, records are dropped and counted.
    pub log_bytes_per_sec: u32,
    /// Whether an exhausted grant asks the hook for more (`on_grant_exhausted`) or is an OOM at once.
    pub ask_before_oom: bool,
}
```

## Hooks: how OSTD calls the endovisor

The endovisor customizes a kernelet's behavior by implementing one trait per kernelet and passing it at creation. OSTD calls these on the kernelet's own task, inside a service call, with the kernelet's page table active, and charges the time to the kernelet. A hook must not block for unbounded time and must not call back into the control half for the same kernelet except where a method says so. The hooks are the only path from a kernelet's requests into the host kernel's Linux functionality.

```rust
pub trait KerneletHooks: Send + Sync + 'static {
    /// A read of `width` bytes (1, 2, 4 or 8) at `offset` in device `dev`'s register file.
    /// Called on the kernelet task that performed the access. Returns the value.
    fn mmio_read(&self, k: &Kernelet, dev: DeviceId, offset: u32, width: u8) -> u64;
    /// The matching write. A write to a virtio queue's notify register is where a
    /// device model walks the queue; it does so through `k.guest_memory()`.
    fn mmio_write(&self, k: &Kernelet, dev: DeviceId, offset: u32, width: u8, value: u64);

    /// A formatted log record from the kernelet's `log` macros, already rate-limited.
    fn log(&self, k: &Kernelet, level: LogLevel, module: &str, line: u32, text: &str);
    /// Bytes from the kernelet's early console (`early_print!`).
    fn console_write(&self, k: &Kernelet, bytes: &[u8]);

    /// The grant is exhausted and `policy.ask_before_oom` is set. Return how many
    /// grains to add, up to `max_grains`; `0` means the kernelet takes the OOM path.
    fn on_grant_exhausted(&self, k: &Kernelet) -> u32 { 0 }

    /// A task of the kernelet took an oops (a caught panic); the budget has been charged.
    fn on_oops(&self, k: &Kernelet, task: TaskName, message: &str) {}
    /// The kernelet has entered `Dying`. Called once, on the task that caused it or on
    /// the host task that called `kill`. The endovisor uses it to stop feeding devices.
    fn on_dying(&self, k: &Kernelet, reason: &ExitReason) {}
    /// Every task has stopped and the kernelet is `Exited`; `destroy` may now be called.
    fn on_exited(&self, k: &Kernelet, status: &ExitStatus) {}
}
```

Device models need to read and write the kernelet's memory: a virtio queue lives in the kernelet's frames. The control half gives them a checked, scoped accessor rather than a mapping:

```rust
impl Kernelet {
    /// Runs `f` with a reader and writer over `len` bytes at physical address `paddr`
    /// of this kernelet's memory. Fails unless every frame of the range is in the
    /// kernelet's grant. The grain is pinned for the duration of `f`, so a concurrent
    /// destroy waits for `f` to return and the kernelet cannot be reclaimed under it.
    /// The reader and writer go through the host's linear map and are valid only inside `f`.
    pub fn guest_memory<R>(
        &self, paddr: Paddr, len: usize,
        f: impl FnOnce(&mut VmReader<'_, Infallible>, &mut VmWriter<'_, Infallible>) -> R,
    ) -> Result<R, MemoryAccessError>;
}
pub enum MemoryAccessError { NotOwned, Dying }
```

This is the one place host code touches a kernelet's memory, it is bounded by a closure, and the pin is what lets [Faults, termination, and reclamation](faults-and-reclamation.md) release frames without a use-after-release: no accessor outlives the pin, and destroy takes every pin before releasing.

## Lifecycle

```rust
pub struct Kernelet { /* host-side state; see below */ }

impl Kernelet {
    /// Builds a kernelet: its slot and identifier, its kernel page table (the host's
    /// with entry 500 replaced), its window with the data template copied in and the
    /// per-virtual-CPU replicas laid out, its initial grant of `initial_grains` grains
    /// mapped into `KW_HEAP`, its shared pages, its device table, its worker task and
    /// its boot task. Nothing runs yet. Fails, with everything undone, if any resource
    /// is unavailable.
    pub fn create(config: KerneletConfig, hooks: Arc<dyn KerneletHooks>) -> Result<Arc<Kernelet>, CreateError>;

    pub fn id(&self) -> KerneletId;
    pub fn state(&self) -> KerneletState;

    /// Makes the boot task runnable. The boot task enters `_kernelet_entry` on the
    /// kernelet's kernel page table; the kernel proper's `main` runs from there.
    pub fn start(&self) -> Result<(), StateError>;

    /// Adds `grains` grains to the grant, up to `max_grains`, and tells the kernelet
    /// through its service table's asynchronous channel so that its frame allocator
    /// sees them. Memory only grows; a kernelet returns memory by exiting.
    pub fn grant(&self, grains: u32) -> Result<u32 /* granted */, GrantError>;

    pub fn set_budget(&self, budget: CpuBudget);

    /// Injects a virtual interrupt: the kernelet's handler for `virq` runs on its
    /// worker task as a job ([Interrupts and time](virtualizing-ostd/interrupts-and-time.md)).
    /// Idempotent while the line is already pending. Cheap: one atomic or, and a wakeup.
    pub fn raise_irq(&self, virq: Virq) -> Result<(), StateError>;

    /// Asks the kernelet to die. Marks it `Dying`, bumps its epoch so every handle it
    /// holds fails on next use, wakes every parked task with a cancellation, and lets
    /// each task reach its next quiescent point, where it is terminated. Returns at once.
    pub fn kill(&self, reason: KillReason);

    /// Blocks the calling host task until the kernelet is `Exited`, or until `timeout`.
    pub fn wait_exited(&self, timeout: Option<Duration>) -> Result<ExitStatus, Timeout>;

    /// Reclaims everything: drains every host table that names this kernelet, unmaps
    /// the window, releases the grant with each frame's host metadata reset, frees the
    /// host objects, and retires the slot. Requires `Exited`. If a device model still
    /// holds a pin or an I/O completion is outstanding, the kernelet becomes a `Zombie`
    /// that stays charged to its owner, and `destroy` can be retried.
    pub fn destroy(self: Arc<Self>) -> Result<ReclaimReport, DestroyError>;

    pub fn stats(&self) -> KerneletStats;
    pub fn config(&self) -> &KerneletConfig;
}

#[derive(Copy, Clone, PartialEq, Eq, Debug)]
pub enum KerneletState { Created, Running, Dying, Exited, Zombie, Destroyed }

pub enum KillReason { Requested, OopsBudget, PreemptOffTooLong, OutOfMemory, HostPolicy(u32) }

pub enum ExitReason {
    /// The kernelet's kernel called `power::poweroff` or `restart` with the code.
    Exited(ExitCode),
    /// A panic that could not be caught inside the kernelet, with its message.
    Panicked(String),
    Killed(KillReason),
}
pub struct ExitStatus { pub reason: ExitReason, pub uptime: Duration, pub cpu_time: Duration }

pub struct ReclaimReport {
    pub grains_released: u32,
    pub tasks_reaped: u32,
    pub handles_revoked: u32,
    pub pending_io_waited: u32,
}

pub struct KerneletStats {
    pub grains_granted: u32,
    pub grains_in_use: u32,        // grains the kernelet's allocator has taken frames from
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

The state machine is linear with one loop: `Created → Running → Dying → Exited → Destroyed`, and `Exited → Zombie → Exited` while a destroy waits for a pin. `kill` is legal in `Running` and `Dying`; `destroy` only in `Exited` or `Zombie`; `grant` and `raise_irq` only in `Created` and `Running`. Every transition is one compare-and-swap on the kernelet's state word, so two host tasks cannot both destroy, and a service call that finds the kernelet `Dying` on entry returns the dying error to the kernelet instead of proceeding ([service half](kernelet-api-service.md)).

## What the host keeps per kernelet

The fields of `Kernelet`, listed so that the destroy sequence can be checked against them and so that invariant I4 can be reviewed: every field is host memory, and the only window addresses among them are the mapping records that destroy unmaps.

| field | what it holds | who writes it |
|---|---|---|
| `id`, `state`, `epoch` | identity; the state word; the handle epoch that `kill` bumps | control half |
| `image`, `config`, `hooks` | the kind, the configuration, the endovisor's hooks | creation |
| `kernel_pt`, `window_l3` | the kernelet's kernel page table root and its private level-3 table for entry 500 | creation; `grant` and metadata growth map into it |
| `grant: Vec<Grain>` | each grain's physical base, its slot (position in this table, which fixes its `KW_HEAP` address), its pin count | `create`, `grant`, `guest_memory`, destroy |
| `tasks: SlotMap<TaskName, Arc<Task>>` | the host tasks that are this kernelet's, by the name the kernelet knows them by; the worker and the boot task among them | the service half's spawn and exit |
| `devices: Vec<DeviceDesc>` and `virqs: [AtomicU64; 4]` | the device table and the pending-interrupt bitmap | creation; `raise_irq`; the worker clears bits |
| `shared: SharedPages` | the frames mapped read-only (`BootArgs`, the info page) and read-write (the task records) into `KW_SHARED` | creation; the scheduler writes task records |
| `accounts` | the counters behind `stats()` and the CPU quota's period accounting | the service half and the scheduler |
| `exit: Once<ExitStatus>`, `exit_waiters: WaitQueue` | the outcome, and who is waiting for it | the last task to stop; `wait_exited` |

Two host-wide tables complete the picture. The **slot table** maps `KerneletId::slot` to the `Arc<Kernelet>` and the current generation, and is how the service half finds the caller's kernelet from the task's record in constant time. The **owner array** has one `Option<KerneletId>` per 2 MiB grain of physical memory, written when a grain is granted and cleared when it is released; it is what `guest_memory` and the service half's ownership checks read, and its size is physical memory divided by 2 MiB times 8 bytes: 4 MiB for a 1 TiB machine.

## Costs

Per kernelet, `create` costs: one level-3 page table plus the level-2 and level-1 tables for the window's populated regions (a few pages for the template and metadata, one level-1 table per 2 MiB of heap, all charged to the kernelet's grant); the data template copy, under 128 KiB *estimated* ([Builds and images](builds-and-images.md)); the per-virtual-CPU replicas at about 2 KiB each, measured on the tree; two shared pages; two tasks with their 512 KiB kernel stacks, which are the largest fixed item. The host-side `Kernelet` object is a few kilobytes. Per grain granted: one level-1 table per 2 MiB for the heap window if the grain is mapped with 4 KiB pages, or one entry if mapped as a 2 MiB page, which is the default ([Memory](virtualizing-ostd/memory.md)), plus one owner-array write. `raise_irq` is one atomic and one wakeup. `kill` is one store to the epoch plus one wakeup per parked task. `destroy` is linear in the number of grains, tasks, devices and pins, and its cost is the drain list of [Faults, termination, and reclamation](faults-and-reclamation.md).

Per hook call, the endovisor pays whatever its device model does; the control half adds the ownership check in `guest_memory`, one owner-array read per grain touched and one pin increment and decrement.

## What this page decides

- **Hooks are a trait object per kernelet, called synchronously on the kernelet's task.** The alternative, a queue of requests served by an endovisor thread, would keep host Linux code off the kernelet's task and its stack, but it turns every device register access into a cross-task round trip with a wakeup, which the earlier prototype measured at 9.4 µs where a function call is 35 cycles. Synchronous hooks keep a register access at function-call cost; the price is that the hook runs on a stack shared with kernelet frames below it and must respect the stack reserve of the service half.
- **Memory only grows.** Reclaiming memory from a running kernelet needs its cooperation, a balloon, and a story for pages the kernelet has mapped to user space; none of that is needed to give every agent a sandbox that exits when it is done. Recorded as an assumption in the register, with the balloon as the extension.
- **Device models live in the endovisor, not in OSTD.** OSTD knows a device only as a register window and an interrupt line. The reason is trust and size: a device model over host files and sockets is Linux functionality, and it is written in the safe-Rust kernel proper, not in OSTD's `unsafe`-bearing framework.
