# What differs between the two hosts

*This chapter's central claim, in one table. The kernel proper's source is untouched and the kernelet image is built from the same code; only vOSTD gains a second backend. This page says exactly which items in that backend differ, which do not, and what the difference costs. If the table is short, API virtualization is host-agnostic; if it is long, it is not.*

## How to read this

The [taxonomy](../design/virtualizing-ostd/index.md) sorts every item of OSTD's API into *identical*, *virtualized* or *absent* for the kernelet build. That sorting does not change here: a kernelet does not know which host it is running on, and the same image runs on either. What changes is how the **host** implements the items that are virtualized.

So this table has one row per mechanism, not per API item, and three columns: what Asterinas does, what Linux does, and whether the kernelet can tell.

## The table

| mechanism | Asterinas host | Linux host | visible to the kernelet? |
|---|---|---|---|
| **image placement** | loader picks an offset in the shared kernel address space | the same, through `vmap()` | no |
| **making text executable** | the host maps it executable | `set_memory_x()` on the mapping — **needs one exported symbol** | no |
| **physical addressing** | the host's linear map, base in boot arguments | Linux's direct map, base in boot arguments | no |
| **frame metadata** | per-instance region at a loader-chosen base | the same, built with `vmap()` | no |
| **grains** | the host's frame allocator | Linux's page allocator, contiguous allocator for runs | no |
| **tasks** | host tasks through `spawn_task` | Linux kernel threads | no |
| **per-CPU data** | OSTD's `cpu_local!` | Linux's per-CPU variables | no |
| **cross-CPU work** | the host's own mechanism | `smp_call_function_single` | no |
| **virtual interrupts** | set a bit, wake the worker | the same, Linux wait queue | no |
| **deferred device work** | the host's device thread | a Linux workqueue or threaded handler | no |
| **time and deadlines** | host clock page and timers | the same, Linux high-resolution timers | no |
| **tenant memory** | the kernelet's own page tables over its grant | a virtual memory area whose fault handler is the kernelet's | no |
| **entering user mode** | `user_run` returns with a reason | Linux enters the tenant; the kernelet never does | **no, but see below** |
| **tenant system calls** | `user_run` returns the reason | Syscall User Dispatch, or the per-task hook | no |
| **device backends** | the endovisor's models over host resources | the same models over Linux subsystems | no |

The last column is the result: **nothing in this table is visible to a kernelet.** Every difference is absorbed by the host side of the kernelet API. That is what "the boundary is the API" means, and it is the strongest form of the claim this chapter set out to test.

## The four places where it is not free

The table is short, but it is not empty, and four rows deserve more than a cell.

**Executable memory.** This is the only hard requirement Linux mode places on the kernel. `vmap()` strips the execute permission, no permission setter is exported, and `execmem_alloc()` is not exported either. One line fixes it. There is no way around it from a module, and this chapter does not pretend there is.

**The tenant's system calls.** The mechanism differs, and so does the cost: 118 ns with the optional patch, 936 ns without, against a bare Linux system call at 46 ns. In Asterinas mode the equivalent is a return from `user_run`, which the Design chapter does not yet measure. So the comparison the reader wants — *is Linux mode slower per system call than Asterinas mode?* — cannot be made yet, and the [evidence](evidence.md) page lists it as the largest open question.

**Frame metadata and the paging level.** On a machine with four-level paging, the address space each instance's metadata region reserves caps the number of kernelets in the low thousands unless the host confines each kernelet's grains to a bounded slice of physical memory. On five-level paging this disappears. It is the one place where the host's paging configuration reaches the design.

**Zero-copy I/O.** The [lending device model](../design/zero-copy-io.md) rests on the host's block and network drivers gaining a non-sleeping submission path. On Asterinas that is work we must do; on Linux the block layer's asynchronous path already exists. The shape carries over; whether the measured argument does has not been checked, and is marked open.

## What this does not show

Two limits on the claim, so that it is not read for more than it is worth.

The chapter demonstrates that the *mechanisms* map onto Linux. It does not demonstrate a running kernelet on Linux: nothing of the kernelet design has been built on either host. What was built and run is the piece each argument turns on — the shared-text scheme, the two module instances, the syscall hook — and those are on the [evidence](evidence.md) page with their transcripts.

And "the same image runs on either host" is a design property this chapter establishes, not an artifact it produces. The [portability requirement](index.md) for this work was the same *source*, recompiled per host. Whether one binary could serve both hosts depends on the boot-argument layout and the service table staying identical, which they do today, but nothing has tested it.
