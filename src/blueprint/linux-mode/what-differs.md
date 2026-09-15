# What differs between the two hosts

*This chapter's central claim, checked item by item against the taxonomy rather than against a list of my own choosing. The kernel proper's source is untouched and vOSTD's source is the same; only the host side of the kernelet API gains a second implementation. This page says which items that implementation changes, which it does not, and where the change reaches through the API to the kernelet or its tenant.*

## How this table was derived

[Virtualizing OSTD](../design/virtualizing-ostd/index.md) sorts every public item of OSTD that the kernel proper uses into *identical*, *virtualized* or *absent*. That sorting is a property of the kernelet build and does not change here: the same source, recompiled, runs on either host.

What can change is the **host side**, so the rows below are exactly the taxonomy's rows that touch it — every item marked *virtualized* that crosses into the host, plus the few marked *identical* that nonetheless rest on something the host provides. The taxonomy's rows that never cross (a per-CPU read, a page-table walk over the kernelet's own frames, a spin lock, the unwinder) cannot differ by host and are not repeated. Where a taxonomy row was checked and found unanswered in Linux mode, it appears here with the gap named, not omitted.

**"Visible" means one of three things**, and the column says which:

- **to the kernelet**: its own code takes a different path, or an operation that succeeds on one host can fail on the other.
- **to the tenant**: a program inside the sandbox could tell, by a result, a failure or a timing it can measure.
- **to the operator**: neither of the above, but the machine differs — a symbol exported, a patch applied, memory or processor time spent.

## The table

| taxonomy item | Asterinas host | Linux host | visible |
|---|---|---|---|
| `paddr_to_vaddr`, `heap`, `Frame`, `Segment` | private window over this kernelet's grains; a wrong address faults | the direct map; every frame on the machine is addressable | **to the kernelet**: fail-stop is lost ([one address space](one-address-space.md)) |
| frame metadata region | per-instance, sparse, loader-chosen base | the same, assembled with `vmap()` | operator: one small-page mapping per page of metadata |
| `FrameAllocOptions`, `grains_request` | the host's frame allocator, bounded slice per kernelet | Linux's page allocator; runs above 4 MiB need an unexported symbol; the allocation may sleep and may fail under fragmentation | **to the tenant**: a grant can fail where it would have succeeded |
| the image itself | one shared read-only mapping per kind, 2 MiB pages | `vmap()` per instance, smallest pages only | operator: translation-buffer entries per instance ([one address space](one-address-space.md)) |
| making the text executable | the host maps it so | `set_memory_rox()` — **needs an exported symbol**, and flushes every processor's translations once per instance | operator |
| `VmSpace::{new, activate}`, `CursorMut`, page-table walk | the kernelet's own page tables over its grant, activated through the host | the tenant's address space is **Linux's**; the kernelet supplies pages through a fault handler and does not own the structure | **to the kernelet**: the kernel proper's memory management must be re-expressed over Linux's interfaces ([the tenant](tenant.md)) |
| `TlbFlusher`, `tlb_shootdown` | the host sends the inter-processor interrupt | Linux's own invalidation, over an address space Linux owns | no |
| `Task`, `TaskOptions`, `spawn_task` | host tasks created by the endovisor | Linux kernel threads, pinned, with a `nice` value | no |
| `task_park`, `task_unpark`, `Mutex`, `WaitQueue` | the host's park and unpark | Linux wait queues | no |
| scheduler injection, `nice`, affinity | the host's scheduler under the kernelet's quota | Linux's scheduler under a control group | **to the tenant**: the same inert-class behavior, different policy underneath |
| `cpu_local!`, replicas | per-instance replica in the kernelet's data | unchanged — the replica is in the image, which is per instance | no |
| cross-processor work | an inter-processor interrupt the host sends itself | `smp_call_function_single` | no |
| `IrqLine`, `JOB_VIRQ` | set a bit, wake the worker | the same, over a Linux wait queue | no |
| bottom halves, deferred device work | the host's device thread | a Linux workqueue or a threaded handler | no |
| `Jiffies`, `register_callback_on_cpu` | the host's clock page and timers | the same, over Linux's high-resolution timers | no |
| `UserMode::execute`, `user_run` | the host switches address space and returns with a reason | **inverted**: Linux enters the tenant, and the kernelet is called from the entry path. There is no `user_run` to return from | **to the kernelet**: this item's contract does not survive; see below |
| process lifecycle: `fork`, `execve`, signal return | the kernel proper creates them through vOSTD | Linux owns task creation, and the hook's shape cannot express a call that returns twice. **Not designed** | **to the tenant**: unresolved ([the tenant](tenant.md)) |
| the virtual system-call page | there is none in a kernelet | Linux maps its own into every process; neither interception mechanism sees it. Must be unmapped or replaced | **to the tenant**: would read the host's clock |
| `IoMem`, `mmio_read`, `mmio_write`, device models | the endovisor's models over host resources | the same models over Linux subsystems | no |
| DMA: `DmaStream`, `DmaCoherent` | `daddr` is `paddr`, no mapping | the same **only where no address-translation unit is enforced**; under Linux's mapping interface a device address is not a physical address. Not addressed here | **to the kernelet**: unresolved on hardware with translation enforced |
| lending rings, zero-copy submission | needs a non-sleeping submission path we must add | the block layer's asynchronous path already has one; whether the measured argument survives the substitution is unchecked | no |
| `stop(STOP_EXIT)`, `power::*`, panic, oops | the host ends the kernelet and reclaims everything | the same, **except that a kernelet looping in kernel mode cannot be stopped**. Invariant I7 does not hold | **to the tenant**: a neighbor can hold a processor ([the tenant](tenant.md)) |
| the kernelet's stack | 512 KiB, with 64 KiB of host headroom (A3) | 16 KiB, shared with Linux's own entry frame | **to the kernelet**: a thirty-two-fold mismatch, unresolved |
| `log_write`, console | the endovisor's log hook | the same, into Linux's log | no |
| accounting: memory and processor time (I6) | the endovisor charges the kernelet | pages handed to a tenant carry no memory-cgroup charge unless the endovisor adds one | **to the operator**: default accounting is wrong |

## Reading the table

Twenty-five rows. **Eleven are invisible in every sense**: the mechanism differs and nothing above the API can tell. They cover tasks, synchronization, interrupts, time, per-CPU data, device access and logging — the bulk of what a kernel does, and the part of the claim that holds cleanly. **Four more are visible only to the operator**, as memory, processor time or a symbol to export. **Ten reach the kernelet or its tenant**, and those are the chapter's real answer.

The rows that are *not* invisible fall into three groups, and they are the honest shape of the answer:

**Two security properties are lost.** A miscomputed physical address is no longer fail-stop, and a runaway kernelet cannot be stopped. Both follow from Linux owning memory and scheduling, and neither has a fix inside this chapter.

**One item's contract does not survive.** `UserMode::execute` is defined as a call that enters user mode and returns with a reason. On Linux the direction is inverted: Linux enters the tenant, and the kernelet is entered *from* the tenant's system-call path. vOSTD can present the same shape to the kernel proper — a loop that hands out a reason — by parking the kernelet's servicing task until the hook delivers one, but the task that runs the kernel proper's system-call code on the patched path is the tenant's own, which is a different arrangement from the one the Design chapter specifies. This is the one row where "the same image runs on either host" is a claim about vOSTD's interface rather than about its implementation, and the process-lifecycle row below it is where that claim is not yet cashed.

**Three things are unfinished rather than different.** Process lifecycle, the virtual system-call page, and device addressing under an enforced translation unit are open design, listed here so they are counted.

## What this does not show

The chapter demonstrates that the *mechanisms* map onto Linux. It does not demonstrate a running kernelet on Linux: nothing of the kernelet design has been built on either host. What was built and run is the piece each argument turns on — the shared-text scheme, the two module instances, the system-call hook — and those are on the [evidence](evidence.md) page with their transcripts.

The per-system-call comparison the reader wants — *is Linux mode slower than Asterinas mode?* — cannot be made. The Linux side is measured; the Asterinas side is a return from `user_run` that the Design chapter does not yet measure, because no kernelet has run.

And "the same image runs on either host" is a design property, not an artifact. The requirement for this work was the same *source*, recompiled per host. Whether one binary could serve both depends on the boot-argument layout and the service table staying identical, which they do today, and nothing has tested it.
