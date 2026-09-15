# What differs between the two hosts

*This chapter's central claim, checked item by item against the taxonomy rather than against a list of our own choosing. The kernel proper's source is untouched and vOSTD's source is the same; only the host side of the kernelet API gains a second implementation. This page says which items that implementation changes, which it does not, and where the change reaches through the API to the kernelet or its tenant.*

## How these tables were derived

[Virtualizing OSTD](../design/virtualizing-ostd/index.md) sorts every public item of OSTD that the kernel proper uses into *identical*, *virtualized* or *absent*. That sorting is a property of the kernelet build and does not change here: the same source, recompiled, runs on either host.

What can change is the **host side**, so the rows below are exactly the taxonomy's rows that touch it — every item marked *virtualized* that crosses into the host, plus the few marked *identical* that nonetheless rest on something the host provides. The taxonomy's rows that never cross (a per-CPU read over the instance's own data, a page-table walk over the kernelet's own frames, a spin lock, the unwinder) cannot differ by host and are not repeated. Where a taxonomy row was checked and found unanswered in Linux mode, it appears with the gap named rather than being omitted.

The rows are split into three tables by **what the difference reaches**:

- **the machine only**: the mechanism differs and nothing above the kernelet API can tell.
- **the operator**: the machine differs in memory, processor time, or a symbol that must be exported, and no program can tell.
- **the kernelet or its tenant**: the kernelet's own code must take a different path, an operation that succeeds on one host can fail on the other, or a program inside the sandbox could tell by a result, a failure or a timing.

## Eleven rows that reach the machine only

| taxonomy item | Asterinas host | Linux host |
|---|---|---|
| `TlbFlusher`, `tlb_shootdown` | the host sends the inter-processor interrupt | Linux's own invalidation |
| `Task`, `TaskOptions`, `spawn_task` | host tasks created by the endovisor | Linux kernel threads, pinned, with a `nice` value |
| `task_park`, `task_unpark`, `Mutex`, `WaitQueue` | the host's park and unpark | Linux wait queues |
| cross-processor work | an inter-processor interrupt the host sends itself | `smp_call_function_single` |
| `IrqLine`, virtual interrupt delivery | set a bit, wake the worker | the same, over a Linux wait queue |
| bottom halves, deferred device work | the host's device thread | a Linux workqueue or a threaded handler |
| `Jiffies`, `register_callback_on_cpu` | the host's clock page and timers | the same, over Linux's high-resolution timers |
| `IoMem`, `mmio_read`, `mmio_write` | the endovisor's device models | the same models over Linux subsystems |
| `boot::boot_info`, the synthesized boot information | from the kernelet's configuration | unchanged |
| `log_write`, console | the endovisor's log hook | the same, into Linux's log |
| `stop(STOP_EXIT)`, `power::poweroff` on a healthy kernelet | the host ends it and reclaims | the same |

## Four rows that reach the operator

| taxonomy item | Asterinas host | Linux host |
|---|---|---|
| the image's mapping | one shared read-only mapping per kind, 2 MiB pages | `vmap()` per instance, smallest pages only: sharing the physical text saves memory, not translation-buffer entries |
| making the text read-execute | the host maps it so | `set_memory_rox()`, which **is not exported**, and which interrupts every processor once per instance |
| `paddr_to_vaddr`, heap, `Frame`, `Segment` | the host's linear map, one add | Linux's direct map, one add — the same shape, a different constant |
| scheduler injection, `nice`, affinity | the host's scheduler under the kernelet's quota | Linux's scheduler under a control group |

## Ten rows that reach the kernelet or its tenant

| taxonomy item | Asterinas host | Linux host | what reaches through |
|---|---|---|---|
| `UserMode::execute`, `user_run` | the host switches address space and returns with a reason | **inverted**: Linux enters the tenant, and the kernelet is entered from the tenant's own entry path | the kernelet: this item's contract does not survive ([below](#user-mode)) |
| process lifecycle: `fork`, `execve`, signal return | the kernel proper creates them through vOSTD | only Linux can create a Linux task, and the hook's shape cannot express a call that returns twice. **Not designed** | the tenant ([the tenant](tenant.md)) |
| `VmSpace::{new, activate}`, `CursorMut`, the page-table walk | the kernelet's own page tables over its grant | the tenant's address space is **Linux's**; the kernelet supplies pages through a fault handler and does not own the structure | the kernelet: its memory management must be re-expressed over Linux's interfaces |
| `VmReader`/`VmWriter` (`Fallible`), the exception table, `inject_user_page_fault_handler` | the host's fault handler consults the kernelet image's own exception table and jumps to its fixup, which invariant I5 bounds | Linux's fault handler searches its own table and the loaded modules', and a kernelet is not a module, so a fixup it would need is **not found**. The answer is to make a fallible copy a service call and let Linux's own copy routine take the fault | the kernelet: a crossing per fallible copy, and a redesign of the fault path |
| a fault in kernelet code that is *not* a fallible copy | tier-2 containment: kill this kernelet, reclaim its memory, the machine continues | a Linux oops on whichever task was running, which kills that task with whatever it held. **Fault containment does not hold** | the tenant: a neighbor's bug reaches further |
| `cpu_local!` and `disable_preempt` | the replica is selected by the virtual CPU in the host's CPU slot, race-free under a preemption count the host honors | Linux honors no such count, and on the patched path the kernel proper runs on the **tenant's own task**, which is not pinned, so the virtual-CPU selector can change under the code. **Unresolved** | the kernelet: every per-CPU access, every preemption-disabled lock, and the read side of read-copy-update |
| `FsBase`, `GsBase` | a base-register or model-specific-register write the host honors | both are per-task state Linux caches and restores at every switch, so a direct write is lost or corrupts Linux's copy. Servicing them needs `x86_fsbase_write_task`, **not exported** | the tenant: thread-local storage |
| frame metadata, invariant I3's remaining check | sparse per-instance region, a wrong address faults | `vmap()` cannot map sparsely or grow, so keeping the check needs `get_vm_area` exported; and with the span unbounded, the regions cap a 1 TiB machine at a few thousand kernelets on four-level paging | the kernelet ([one address space](one-address-space.md)) |
| `FrameAllocOptions`, a grant | the host's own frame allocator | Linux's page allocator to 4 MiB and the contiguous allocator above it; either may sleep, and either can fail under fragmentation where a host that owned its allocator would not | the tenant: a grant can fail where it would have succeeded |
| termination, `stop` on an unhealthy kernelet, accounting | invariant I7: a task at depth zero can be terminated and its stack discarded; the endovisor charges every page | Linux cannot stop a task running in kernel mode, and pages handed to a tenant carry no memory-cgroup charge unless the endovisor adds one | the tenant: a neighbor can hold a processor, and can escape accounting ([the tenant](tenant.md)) |

One row is deliberately not in any of the three. The [zero-copy design](../design/zero-copy-io.md)'s lending rings need a non-sleeping submission path, which is work we must do on Asterinas and which Linux's block layer already has. The shape carries over; whether the measured argument survives the substitution is **unchecked**, so the row has no verdict yet.

Two rows in the third table have no verdict either, in a different sense: *device addressing* under an enforced address-translation unit, where a device address is not a physical address and the design assumes it is, is not addressed for either host; and the tenant's **virtual system-call pages**, which Linux maps into every process and which neither interception mechanism sees. The modern one must be unmapped or replaced, and that is not designed; the legacy one is emulated below every interception point and must be turned off on the kernel command line, which is an operator requirement Linux mode adds.

## Reading the tables {#user-mode}

Eleven rows of twenty-five change nothing anyone can observe. They cover tasks, synchronization, interrupts, time, device access, boot and logging — the bulk of what a kernel does, and the part of the claim that holds cleanly. Four more cost the operator memory, processor time or an export.

The ten that reach further are the chapter's real answer, and they fall into three groups.

**Three things the boundary owed are weakened.** Fault containment fails twice over — once because a kernelet's own exception table is invisible to Linux's fault handler, and once because any other fault in kernelet code is an oops rather than a contained kill. Termination fails because Linux will not stop a task in kernel mode. Fair accounting fails by default, because a tenant's pages are charged to nobody. None of the three has a fix inside this chapter; all three are Asterinas-mode properties.

**One item's contract does not survive.** `UserMode::execute` is defined as a call that enters user mode and returns with a reason. On Linux the direction is inverted: Linux enters the tenant, and the kernelet is entered *from* the tenant's system-call path. vOSTD can present the same shape to the kernel proper, by parking a servicing task until the hook delivers a reason, but the task that then runs the kernel proper's code is the tenant's own — which is also what breaks the per-CPU row above. This is the one place where "the same image runs on either host" is a claim about vOSTD's interface rather than about its implementation.

**Four things are unfinished rather than different.** Process lifecycle, the per-CPU and preemption model, the virtual system-call page, and device addressing under an enforced translation unit. Each is listed here so that it is counted rather than discovered later.

## What this does not show

The chapter demonstrates that the *mechanisms* map onto Linux. It does not demonstrate a running kernelet on Linux: nothing of the kernelet design has been built on either host. What was built and run is the piece each argument turns on — the shared-text scheme, the two module instances, the system-call hook — and those are on the [evidence](evidence.md) page with their transcripts.

The per-system-call comparison the reader wants — *is Linux mode slower than Asterinas mode?* — cannot be made. The Linux side is measured; the Asterinas side is a return from `user_run` that the Design chapter does not yet measure, because no kernelet has run.

And "the same image runs on either host" is a design property, not an artifact. The requirement for this work was the same *source*, recompiled per host. Whether one binary could serve both depends on the boot-argument layout and the service table staying identical, which they do today, and nothing has tested it.
