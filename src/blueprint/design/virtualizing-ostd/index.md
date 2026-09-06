# Virtualizing OSTD

*Answers question 2: how is the API of OSTD (kernelet build) virtualized, item by item?*

This page is the taxonomy. Every public item of OSTD that the kernel proper uses, as enumerated in the [OSTD API inventory](../../../notes/ostd-api-inventory.md), is one of three things in the kernelet build, and the tables below say which, how a virtualized item is implemented, which service-half function or shared page it relies on, what it costs, and what a tenant can observe. The six pages that follow hold the mechanisms: [Memory](memory.md), [Tasks, scheduling, and CPUs](tasks.md), [Interrupts and time](interrupts-and-time.md), [User mode](user-mode.md), [Devices](devices.md), and [Boot, power, panic, and the rest](the-rest.md).

## The three kinds

- **Identical.** The item's source has no `cfg(feature = "kernelet")` in it. It compiles into the kernelet image unchanged and has the same semantics, because its effect is local to the caller: it takes no host lock, allocates nothing the host keeps, stores no pointer to its argument that outlives the call, and queues no closure.
- **Virtualized.** The item keeps its public name and signature and gets a second body under the feature. The body serves the request from the kernelet's own state in its window, from a shared page, or through a service-table call. Some virtualized items never cross into the host (a `cpu_local!` read, `Jiffies::elapsed`); some always do (`Task::spawn`, an `IoMem` register write); the table says which.
- **Absent.** The item is `cfg(not(feature = "kernelet"))`. A use of it fails to compile in the kernelet build with an unresolved name. Every absent item is either a machine operation a tenant must never have, or something whose only users are the components that stay in the host kernel.

The classification is executable, not a list to be trusted. For every item marked identical, a test in `ostd`'s kernelet-build test suite calls it under instrumentation that counts host lock acquisitions, records every physical address written, and scans host structures for window addresses afterward; an identical item must leave all three unchanged. The test is what keeps the table true as OSTD changes (invariant I8).

## Counting

Over the inventory's items, grouped as the tables below group them and counted per row: 26 rows identical, 37 virtualized (of which 21 never cross into the host), 8 absent, and one internal to OSTD. Of the absent rows, every one but the interrupt-remapping index has its users in host-only components; the four `cfg` lines the kernel proper's own code needs are listed at the end of the page. Counted over this page's tables; the inventory's import counts say how widely each item is depended on.

## `mm`: memory

| item | kind | how, and what it relies on | cost | what a tenant sees |
|---|---|---|---|---|
| `VmIo`, `VmIoOnce`, `VmIoFill`, `HasVmReaderWriter`, `VmReaderWriterResult` | identical | traits over readers and writers | none | nothing |
| `VmReader`, `VmWriter` (`Infallible`) | identical | kernel-space cursors; the pointers they hold are window or stack addresses | none | nothing |
| `VmReader`, `VmWriter` (`Fallible`) | virtualized | the copy routines are identical, with their exception-table entries; the *fault* is handled by the host and completed by a retry loop in the kernelet build that calls the kernel's injected page-fault handler ([User mode](user-mode.md)) | one extra round trip per first-touch fault | nothing |
| `Fallible`, `Infallible`, `FallibleVmRead`, `FallibleVmWrite`, `PodOnce`, `PodAtomic` | identical | markers and traits | none | nothing |
| `PAGE_SIZE`, `Vaddr`, `Paddr`, `Daddr`, `PagingLevel`, `MAX_USERSPACE_VADDR`, `KERNEL_VADDR_RANGE` | identical | constants | none | nothing |
| `HasPaddr`, `HasSize`, `HasDaddr`, `HasPaddrRange`, `Split` | identical | traits | none | nothing |
| `FrameAllocOptions` | identical | calls the kernel proper's own global frame allocator, which manages the kernelet's grains; zeroing writes through the virtualized `paddr_to_vaddr` | none per call; a grain request when the allocator is empty | `ENOMEM` when the grant is exhausted ([Memory](memory.md)) |
| `GlobalFrameAllocator` (hook) | identical | the kernel's allocator is fed grains by `add_free_memory` at boot and on each `JOB_GRANT` | none | nothing |
| `Frame<M>`, `UFrame`, `Segment<M>`, `USegment`, `UniqueFrame<M>`, `FrameRef` | virtualized, no crossing | same API; the metadata slot lives in the kernelet's own `KW_META` array, found through the grant table, not in the host's global array | one grant-table lookup per metadata access | nothing |
| `AnyFrameMeta`, `AnyUFrameMeta`, `impl_frame_meta_for!`, `impl_untyped_frame_meta_for!`, `GetFrameError`, `FRAME_METADATA_MAX_SIZE` | identical | the metadata protocol, over the kernelet's own slots | none | nothing |
| `frame::linked_list::{LinkedList, Link, CursorMut}` | identical | intrusive lists over the kernelet's own metadata | none | nothing |
| `heap::GlobalHeapAllocator` (hook), `HeapSlot`, `SlotInfo`, `Slab`, `SlabMeta`, `SlabSlotList` | virtualized, no crossing | same API; `HeapSlot::paddr` and `as_ptr` translate through the heap window, and `alloc_large` maps its segment there | one translation per slot operation | nothing |
| `kspace::paddr_to_vaddr` | virtualized, no crossing | `KW_HEAP + slot(pa) × 2 MiB + offset` through the grant table, never the linear map | one lookup | nothing |
| `kspace::{KVirtArea, kernel_loaded_offset, LINEAR_MAPPING_*, VMALLOC_*}` | absent | kernel-half virtual memory is the host's; no user in the kernel proper | | |
| `VmSpace::new` | virtualized, no crossing | copies the kernel half from the kernelet's kernel page table (its 256 entries are in `BootArgs`) into a root frame from the grant | none beyond today's | nothing |
| `VmSpace::activate` | virtualized | `pt_root_register` on first activation, `pt_activate` on each | one crossing per activation; the CR3 write | nothing |
| `VmSpace::{cursor, cursor_mut, reader, writer}`, `Cursor`, `CursorMut::{query, find_next, jump, map, unmap, protect_next}`, `VmQueriedItem`, `PageProperty`, `PageFlags`, `CachePolicy` | virtualized, no crossing | the page-table walk is identical; leaf and table frames come from the grant; a node frame's metadata is the kernelet's | none beyond today's | nothing |
| `CursorMut::flusher`, `tlb::{TlbFlusher, TlbFlushOp}` | virtualized | remote invalidation through `tlb_shootdown`, since a kernelet cannot send interrupts | one crossing and one IPI per target CPU per flush batch | nothing |
| `CursorMut::map_iomem`, `find_iomem_by_paddr` | virtualized | fails with `Error::AccessDenied`; a virtual device's registers are not memory | none | `mmap` of device memory fails with `EACCES` |
| `dma::{DmaStream, DmaCoherent, DmaDirection, ToDevice, FromDevice, FromAndToDevice}` | virtualized, no crossing | frames from the grant; `daddr` is `paddr`; `sync_*` are no-ops; ownership of a descriptor's frames is checked by the device model, not here ([Devices](devices.md)) | none | nothing |
| `fault::inject_user_page_fault_handler` | identical | the hook is stored and called kernelet-side by the retry loop above | none | nothing |
| `page_table::*` | internal | not public to the kernel proper | | |

## `sync`: synchronization

| item | kind | how, and what it relies on | cost | what a tenant sees |
|---|---|---|---|---|
| `SpinLock`, `SpinLockGuard`, `RwLock` and its guards, `SpinGuardian`, `PreemptDisabled`, `GuardTransfer` | identical | spin locks over kernelet state; the preemption count is the task record's | none | nothing |
| `LocalIrqDisabled`, `WriteIrqDisabled`, `SpinLock::disable_irq` | virtualized, no crossing | the guardian disables preemption instead of interrupts; sound because no kernelet code runs in interrupt context ([Interrupts and time](interrupts-and-time.md)) | none | nothing |
| `Mutex`, `MutexGuard`, `RwMutex` and its guards, `WaitQueue`, `Waiter`, `Waker` | virtualized | identical logic over `task_park` and `task_unpark` by name; a waker holds a task name, not an `Arc<Task>` ([Tasks](tasks.md)) | one crossing per park and per wake | nothing |
| `Rcu`, `RcuOption`, their read guards, `non_null::*` | identical | the read side is preemption-disabled reads | none | nothing |
| `RcuDrop`, the write side | virtualized, no crossing | grace periods tracked per virtual CPU in the kernelet build; callbacks run on the worker at ticks ([Tasks](tasks.md)) | callbacks are deferred to the next tick rather than the next switch | nothing |
| `RwArc`, `RoArc` | identical | | none | nothing |

## `task`: tasks and scheduling

| item | kind | how, and what it relies on | cost | what a tenant sees |
|---|---|---|---|---|
| `Task`, `TaskOptions`, `CurrentTask` | virtualized | a kernelet-side `Task` is a name plus the kernel's `data` and `local_data`; `spawn` stores the closure in the kernelet's heap under an entry index and calls `task_spawn`; `current` reads the CPU slot; `yield_now` is `task_yield`; `run` is `task_unpark` ([Tasks](tasks.md)) | one crossing per spawn, yield and run | nothing |
| `disable_preempt`, `DisabledPreemptGuard` | virtualized, no crossing | increments the task record's `preempt_count`, which the host tick honors | one store | nothing |
| `halt_cpu` | virtualized | parks the idle task until the host reports the virtual CPU idle again ([Tasks](tasks.md)) | one crossing | nothing |
| `scheduler::inject_scheduler`, `Scheduler`, `LocalRunQueue`, `EnqueueFlags`, `UpdateFlags`, `info::*`, `AtomicCpuId`, `enable_preemption_on_cpu` | virtualized, no crossing | accepted and not consulted: the host's scheduler runs the kernelet's tasks within its group; the kernel proper's scheduler classes are inert inside a kernelet | none | `nice`, `sched_setscheduler` and real-time policies have no effect inside a kernelet; every thread of a kernelet is scheduled alike by the host |
| `atomic_mode::{InAtomicMode, AsAtomicModeGuard, might_sleep}` | identical | | none | nothing |
| `inject_pre_schedule_handler`, `inject_post_schedule_handler` | virtualized, no crossing | called by the kernelet build around its own voluntary switch points; involuntary switches are the host's, which saves and restores the user FS and GS bases and the FPU state itself ([Tasks](tasks.md)) | XSAVE and XRSTOR per involuntary switch | nothing |

## `irq`, `timer`: interrupts and time

| item | kind | how, and what it relies on | cost | what a tenant sees |
|---|---|---|---|---|
| `IrqLine::{alloc, alloc_specific, num, on_active, is_empty}`, `IrqCallbackFunction` | virtualized | virtual lines; a callback runs on the worker of the virtual CPU the line is bound to, in task context, when the host posts `JOB_VIRQ` ([Interrupts and time](interrupts-and-time.md)) | a wakeup per interrupt | nothing |
| `IrqLine::remapping_index` | absent | interrupt remapping is the host's | | |
| `disable_local`, `DisabledLocalIrqGuard` | virtualized, no crossing | disables preemption | one store | nothing |
| `InterruptLevel` | identical | always reports task context in a kernelet | none | nothing |
| `register_bottom_half_handler_l1`, `_l2` | virtualized, no crossing | run on the worker after each virtual interrupt's top half | none | nothing |
| `Jiffies`, `TIMER_FREQ` | virtualized, no crossing | `elapsed` reads the info page's `jiffies` | one load | time is the host's |
| `register_callback_on_cpu` | virtualized | per-virtual-CPU callbacks run on that CPU's worker on `JOB_TICK`; ticks are posted only while the virtual CPU has run since the last tick | a wakeup per tick per busy virtual CPU | nothing |

## `cpu`, `user`: CPUs and user mode

| item | kind | how, and what it relies on | cost | what a tenant sees |
|---|---|---|---|---|
| `CpuId`, `CpuSet`, `AtomicCpuSet`, `num_cpus`, `all_cpus`, `CpuId::current_racy` | virtualized, no crossing | the virtual CPU namespace from `BootArgs`; `current` reads the CPU slot's `vcpu` | one load | `nproc` is the kernelet's CPU count |
| `PinCurrentCpu`, `PrivilegeLevel` | identical | | none | nothing |
| `cpu_local!`, `cpu_local_cell!`, `StaticCpuLocal`, `CpuLocalCell` | virtualized, no crossing | the replica for the current virtual CPU, addressed as `replica_base + vcpu × replica_bytes + offset`; single-instruction operations become load-and-store under a preemption guard | two loads per access instead of a GS-relative one | nothing |
| `DynamicCpuLocal`, `DynCpuLocalChunk` | absent | no user in the kernel proper | | |
| `UserMode::{new, context, context_mut}`, `UserContextApi`, `UserModeHooks`, `ReturnReason`, `UserContext`, `GeneralRegs`, `CpuException`, `CpuExceptionInfo`, `RawPageFaultInfo`, `PageFaultErrorCode`, `FpuContext` | identical | value types and the loop's hooks | none | nothing |
| `UserMode::execute` | virtualized | the loop is identical; the ring transition is `user_run` ([User mode](user-mode.md)) | one crossing per round trip, on top of the transition | nothing |
| `FsBase`, `GsBase` | identical | MSR writes under a preemption guard, which the host honors as it honors interrupt disabling today | none | nothing |

## `io`, `bus`: devices

| item | kind | how, and what it relies on | cost | what a tenant sees |
|---|---|---|---|---|
| `IoMem::{acquire, acquire_with_cache_policy, slice, cache_policy}` | virtualized, no crossing | an `IoMem` is a `(device, offset, len)` triple over a virtual device from `BootArgs`, not a mapping | none | nothing |
| `IoMem::{read_fallible, write_fallible}` and its `VmIoOnce` | virtualized | every access is `mmio_read` or `mmio_write` to the endovisor's device model ([Devices](devices.md)) | one crossing and one hook call per register access | nothing |
| `IoPort` and `arch::device::io_port::*` | absent | port I/O is the host's; used only by host-only components | | |
| `bus::BusProbeError` | identical | | none | nothing |

## `boot`, `smp`, `power`, `console`, `log`, `panic`, `util`, `prelude`

| item | kind | how, and what it relies on | cost | what a tenant sees |
|---|---|---|---|---|
| `boot::boot_info`, `BootInfo`, `EarlyCmdline`, `MemoryRegion`, `MemoryRegionType` | virtualized, no crossing | synthesized from `BootArgs`: the command line from the configuration, one `Usable` region per initial grain, no ACPI, no framebuffer, no initramfs unless the endovisor attaches one as a device ([The rest](the-rest.md)) | none | `/proc/cmdline`, `/proc/meminfo` reflect the configuration |
| `boot::smp::register_ap_entry` | virtualized | the entry runs once on each virtual CPU above 0, on a task the kernelet build spawns pinned there during its init | one spawn per virtual CPU | nothing |
| `smp::{inter_processor_call, PendingIpis}` | absent | a kernelet cannot interrupt a CPU; no user in the kernel proper | | |
| `power::{poweroff, restart}`, `ExitCode` | virtualized | `exit(code)`; the injected handlers are accepted and not called | one crossing, final | `reboot(2)` ends the kernelet with the code |
| `power::inject_restart_handler`, `inject_poweroff_handler` | virtualized, no crossing | stored, unused | none | nothing |
| `console::{early_print, early_println}` | virtualized | `console_write` | one crossing per call | output goes to the endovisor's console hook |
| `console::uart_ns16650a::*` | absent | used only by the host-only `uart` component | | |
| `log` macros, `Log`, `Record`, `Level`, `LevelFilter`, `inject_logger`, `set_max_level`, `max_level` | virtualized | formatting and filtering are identical; the default sink, when no logger is injected, is `log_write`; the kernelet's `logger` component is host-only, so none is | one crossing per record under the rate limit | records reach the endovisor's log hook |
| `panic::{catch_unwind, begin_panic, print_stack_trace}` | identical | the unwinder and its tables are in the image | none | nothing |
| `panic::abort` | virtualized | `panic(msg)`: ends the kernelet, never the machine | one crossing, final | a kernel panic ends the sandbox |
| `#[ostd::panic_handler]` | identical | the kernel's oops handling runs in the kernelet; its final `abort` is the virtualized one | none | nothing |
| `#[ostd::main]` | virtualized, no crossing | the expansion under the feature parks the boot task after `main` returns instead of asserting there is no current task and powering off | none | nothing |
| `#[ostd::global_frame_allocator]`, `#[ostd::global_heap_allocator]`, `#[ostd::global_heap_allocator_slot_map]`, `#[ostd::early_cmdline_parser]` | identical | the hooks are bound inside the kernelet image | none | nothing |
| `util::*`, `prelude::*`, `Error`, `Result` | identical | | none | nothing |

## `arch` (x86-64)

| item | kind | how, and what it relies on | cost | what a tenant sees |
|---|---|---|---|---|
| `cpu::context::*` (listed under `user` above) | identical | | | |
| `trap::{TrapFrame, USER_CS_VALUE, USER_SS_VALUE}` | identical | value type and constants | none | nothing |
| `read_tsc`, `read_random`, `cpu::cpuid::cpuid` | identical | unprivileged or ring-0 instructions with local effect | none | nothing |
| `tsc_freq` | virtualized, no crossing | `BootArgs::tsc_freq_hz` | none | nothing |
| `irq::{IRQ_CHIP, IrqChip, MappedIrqLine, InterruptSourceInFdt}` | absent | the interrupt controller is the host's; the virtio MMIO bus layer that uses it gets a `cfg` line ([Devices](devices.md)) | | |
| `kernel::ACPI_INFO`, `boot::DEVICE_TREE`, `serial::SERIAL_PORT` | absent | used only by host-only components | | |

## The kernel proper's own `cfg` lines

Four absent items have users in `kernel/core/src` rather than in host-only components, and each gets a `cfg` on the offending lines; the list is exhaustive by the inventory's file scan:

1. `init.rs`: `register_ap_entry` stays (virtualized); the idle loops' `halt_cpu` stays (virtualized); the `panic!` that ends the host when init exits becomes `power::poweroff(code)` under the feature, so that a kernelet whose init exits ends with `Exited(code)` rather than `Panicked`.
2. `arch/x86/power.rs`: the ACPI power-off and reset paths are `cfg(not(feature = "kernelet"))`; the injected handlers become no-ops.
3. `time/softirq.rs`, `time/cpu_time_stats.rs`, `sched/stats/scheduler_stats.rs`, `process/process/timer_manager.rs`: these use `cpu_local!` and the tick, both virtualized; no line changes, listed because the inventory's scan flagged them as machine-touching through `CpuId::current_racy`, which is virtualized.
4. `thread/mod.rs`: the schedule handlers stay (virtualized); the context-switch counter's `add_on_cpu` stays over the virtualized `cpu_local!`.

Every other difference between the kernel proper as host and as kernelet is a component present in one build and not the other ([Builds and images](../builds-and-images.md#two-builds)), and the virtio MMIO transport's bus enumeration, which reads `BootArgs` instead of a device tree or ACPI.
