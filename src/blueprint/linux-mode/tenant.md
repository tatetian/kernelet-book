# The tenant: user mode and system calls

*The hardest part of Linux mode. A kernelet must run its tenant's programs and answer their system calls, and Linux gives an out-of-tree component no way to do either directly. This page works through what Linux does offer, measures the candidates, and reaches a conclusion that matters more than any of the costs: the patch is not a performance option. It is what decides whether the kernelet is the tenant's boundary at all. What the design assumed and Linux does not provide is collected on the [page after this one](not-as-assumed.md).*

## Why this is hard

In Asterinas mode the answer is short. vOSTD calls `user_run`, the host switches to the tenant's address space and returns to user mode, and when the tenant makes a system call the host returns from `user_run` with the reason ([User mode](../design/virtualizing-ostd/user-mode.md)). The host is ours; we wrote the entry path.

On Linux neither half of that is available.

**A kernel thread cannot return to user mode.** A kernel thread is dispatched at creation to a function that never leaves the kernel, and it has no saved user register state to return to. Borrowing a process's address space with `kthread_use_mm()` deliberately does not change that: it lets the thread read and write that process's memory, not become it.

**No module can intercept a task's system calls.** Linux diverts a call in three places — syscall user dispatch, ptrace, seccomp — and all three are driven from user space. A tracing probe can watch a call, or change its number, but nothing in the kernel can *answer* one on a module's behalf. On x86-64 there is not even a table to patch: the dispatch is a `switch` compiled into the entry path, and the old system-call table survives only for tracing.

## The shape of the answer

Since the kernelet cannot create a user-mode context, it borrows one: **the tenant's processes are Linux processes**. Linux schedules them, enters and leaves them, and handles their traps. What changes is who answers their system calls and who supplies their memory.

Memory is the easier half and needs no patch. The endovisor gives the tenant's address space a **virtual memory area whose fault handler is the kernelet's**, so when the tenant touches an address, Linux calls that handler and the kernelet supplies a frame from its own grant.

That sentence is short because the mechanism is standard. What it buys is narrower than it sounds, and the limits are worth stating in full, because they decide whether the design is buildable.

**The pages are not ordinary pages.** A module has two ways to supply one. It can return a page from a folio it owns, which puts the page on Linux's reclaim lists under rules the kernelet does not control. Or it can mark the area as holding raw frame numbers and insert them directly, which is what device drivers do. The second is the right shape here and it costs a list of things the tenant can no longer do: the kernel's pinning interface refuses such pages, so direct file I/O, `vmsplice`, cross-process reads, registered buffers for asynchronous I/O and remote direct memory access all fail on them; a debugger cannot read them; and `fork` cannot copy them on write. They are also outside the reverse map, so nothing can migrate, compact or reclaim them.

**Linux does not tell the kernelet when a mapping goes away.** Tearing down an area — `munmap`, discarding pages, a process exiting — does not consult the handler that supplied them. The kernelet's own record of which of its frames are mapped where would go stale silently, and keeping it true needs a design this chapter does not have.

**A module cannot create an area in another task's address space.** There is no exported way to do it, and the interfaces that exist act on the caller's own. So the kernel proper's `mmap`, `brk` and program loading can run only while the kernelet is executing **on the tenant's own task**. Both paths can arrange that — on the unpatched path the stub's handler calls into the endovisor from the tenant's own thread — but the arrangement that cannot work is the one that would otherwise be natural: parking a servicing kernel thread and handing it the reason. Address-space work must run on the task whose address space it is.

**Linux keeps the address-space structure**, and therefore `mmap`, `mprotect`, `mremap`, reclaim and copy-on-write, so the kernel proper's memory management must be re-expressed over Linux's interfaces rather than carried across. And pages handed out this way carry no memory-cgroup charge unless the endovisor adds one, so a tenant's memory escapes accounting by default.

System calls are the hard half.

## The four candidates, measured

Two machines were used, and the tables are kept apart so that nothing is compared across them. Guest figures are medians of five runs.

Measured in the **guest**, where a call Linux services itself costs 44 ns:

| mechanism | median | overhead | needs a patch |
|---|---|---|---|
| a call Linux services itself | 44 ns | — | — |
| **Syscall User Dispatch** | ≥929 ns | **+885 ns** | no |
| **per-task hook** | 39 ns | below the noise | yes |

Measured on the **build host**, where the floor is 485 ns:

| mechanism | per call | overhead |
|---|---|---|
| Syscall User Dispatch | 1,887 ns | +1,402 ns |
| seccomp user notification | 5,721 ns | +5,236 ns |
| `ptrace(PTRACE_SYSEMU)` | 8,221 ns | +7,736 ns |

Those are single runs rather than medians, which is enough to separate mechanisms an order of magnitude apart and not enough for anything finer.

The hook measures *faster* than a bare `getppid` because the servicer used for the measurement returns a constant while `getppid` does real work. So the number does not say a kernelet is free. It says that **the hook adds nothing measurable to Linux's entry path**: reaching a kernelet costs about what reaching Linux's own handler costs, and the kernelet's actual work is the kernel proper's code, identical on both hosts.

**Read the overheads, not the ratios.** The guest is a minimal kernel with no speculative-execution mitigations, no page-table isolation and no indirect-branch thunks, so its floor is ten times lower than a production host's and any ratio taken against it flatters. Syscall User Dispatch costs +885 ns in the guest and +1,402 ns on the mitigated host: the same order, and that is as much as this supports. On a production kernel both paths grow — dispatch pays two more ring transitions, which page-table isolation makes worse, and the hook's indirect call becomes a thunk — and which grows faster was **not measured**. **[unverified]**

Two candidates fall away on measurement. Both seccomp user notification and ptrace put the answer in a *different process*, so each tenant call becomes a pair of context switches to a supervisor and back. On the same machine they cost three to four times what Syscall User Dispatch costs.

One clarification, since it is easy to get wrong: **gVisor does not use seccomp user notification.** Its current platform, systrap, uses a seccomp filter that *traps*, raising `SIGSYS` in the calling thread, with a stub handler that reaches gVisor's kernel through shared memory. That is the same shape as Syscall User Dispatch, not the shape rejected here. gVisor has spent years optimizing that path; none of its techniques was tried here, and they are the obvious thing to aim at the +885 ns.

## The no-patch path, and the hole in it

Syscall User Dispatch lets a process ask Linux to stop executing its system calls and raise a signal instead, with one byte in the process's own memory deciding whether the diversion is on.

The sandbox is set up like this. The kernelet runtime starts the tenant's first process with a small **stub** mapped into it. The range handed to Linux is the range that is *exempt*, so the stub goes **inside** it and the stub's own calls run normally while everything outside traps. The stub arms dispatch and sets the selector byte to *block*. From then on: the tenant executes a system call; Linux raises `SIGSYS` instead of running it; the stub's handler makes one call into the endovisor carrying the register set; the kernelet services it; the stub writes the result into the signal frame and returns; the tenant resumes.

Two honest notes about the 929 ns. The program that produced it ran with no exempt range, and a handler that filled in a result directly. So it measures the signal delivery and the return, steps one and four, and not the call into the endovisor in between. A real stub adds at least one more kernel entry. **The figure is therefore a floor**, written ≥929 ns in the table above and quoted elsewhere as the overhead it implies, at least +885 ns.

And now the part that decides the chapter.

**On this path the tenant can reach Linux's own system calls.** Three ways, none exotic.

The selector byte lives in the tenant's memory, so the tenant can store *allow* and make an ordinary call. It can jump to the `syscall` instruction inside the stub, which is in the exempt range by construction, with registers of its own choosing. And it can simply **fork or exec**: Linux clears the dispatch setting in `copy_process()` and again in `begin_new_exec()`, and [the manual](https://docs.kernel.org/admin-guide/syscall-user-dispatch.html) says so — any fork or exec of the process resets the mechanism to off. So without a patch, only the tenant's *first thread* is ever intercepted. Every child runs with its calls going straight to Linux from its first instruction, and nothing inside the sandbox can re-arm the setting before that instruction runs.

So on the no-patch path the kernelet is **not** the tenant's boundary. What confines the tenant is Linux's own machinery: an unprivileged user id, a set of namespaces, and a seccomp filter — which is the container boundary this work exists to improve on. The Paper opens by observing that a tenant which finds a global the namespaces do not partition has found its neighbors; on this path that sentence applies to a kernelet's tenant too.

Two of the three can be narrowed. The selector pointer is **optional**: dispatch may be armed with no selector at all, in which case every call outside the exempt range is diverted unconditionally and there is no byte to flip. And a seccomp filter over the tenant turns "the whole Linux system-call interface" into "whatever the filter allows", which is what gVisor does and is worth doing. The jump into the exempt range cannot be closed, and neither can the fork.

[Linux's own documentation](https://docs.kernel.org/admin-guide/syscall-user-dispatch.html) reaches this chapter's conclusion in its own voice, and names the same two escapes this page derived: "It is not a mechanism for sandboxing system calls, and it should not be seen as a security mechanism, since it is trivial for a malicious application to subvert the mechanism by jumping to an allowed dispatcher region prior to executing the syscall, or to discover the address and modify the selector value. If the use case requires any kind of security sandboxing, Seccomp should be used instead."

## The patched path, and why it is the real one

The patch adds one field to the task structure and one branch at the top of the system-call path: if this task has a kernelet, call it instead of dispatching. There is no selector for the tenant to flip and no exempt range to jump into. **The kernelet becomes the tenant's only system-call surface**, which is what the design claims everywhere else and what the no-patch path cannot deliver.

That is the argument for the patch. The difference in cost is real and secondary: leading with it would make a security mechanism look like an optimization.

**The patch as first measured had two defects, both found in review.** It returned a value meaning *leave through the slow exit path*, which sent every serviced call out the expensive way and skipped the checks that would have allowed the fast one; that, and not the hook, was most of the cost first reported. And it did not test for the marker meaning *an earlier stage already answered this call*, so attaching a kernelet would have overridden that task's seccomp verdict. Both are fixed and the numbers above are from the fixed version.

**What is still wrong with it** is recorded rather than repaired, because it changes the size of the ask:

- **Only one entry point is hooked, and there are four.** A kernel built with 32-bit compatibility — which production kernels are — also enters through the legacy software interrupt, through the 32-bit fast-call instruction, and through the older 32-bit entry instruction. Two more hook sites cover all four, since the last of them tail-calls the third. Neither is written, and a tenant that enters by an unhooked path has its call serviced by Linux, with its own credentials, invisibly to the kernelet. That is a complete escape, and the guest used here had compatibility compiled out, so it could not appear in the measurement.
- **A fifth path bypasses the hook even with compatibility off.** The legacy virtual system-call page at a fixed high address is emulated inside the page-fault handler, which calls three system calls directly and never reaches the dispatch path, seccomp, or the hook. It is compiled into distribution kernels and its mode is a boot-time setting, so the endovisor cannot turn it off per tenant. Linux mode must require `vsyscall=none` on the kernel command line, and that is an operator requirement, not a patch.
- **No lifetime management.** `fork` copies the two fields into the child, nothing clears them when a task exits, and nothing takes a reference on the module, so unloading it can leave a task pointing into freed memory.
- **The return-value convention is unstated.** Several negative values mean *restart this call* to Linux's signal machinery; a kernelet returning one would have its call silently re-executed.

**Would it be accepted upstream?** No, not as posted. A version with a chance would be framed as a generalization of Syscall User Dispatch — an in-kernel dispatch target instead of a signal — gated behind a configuration option, with an in-tree user and the lifetime rules worked out.

## What is missing entirely

Two gaps larger than anything above, stated because the chapter would be dishonest without them.

**Process lifecycle.** The hook's shape — take a register set, return a value — cannot express `fork`, which returns twice; `execve`, which replaces the address space and the register file; or the return from a signal handler, which restores a saved frame. Only Linux can create a Linux task, and the functions that do so are not available to a module. How a kernelet's processes map onto Linux tasks, and who owns the tenant's signals, is **not designed here**, and it is the largest open item in this chapter.

**The virtual system-call page.** Some calls — reading the clock, asking which processor you are on — are served from a page Linux maps into every process, without entering the kernel at all. Neither dispatch nor the hook sees them, so a tenant would read the *host's* clock rather than its kernelet's. The endovisor must unmap that page from its tenants or supply its own. This is the modern page, and it is a correctness problem; the legacy page named above is a separate and more serious one.

## What this page decides

The decisions are recorded in the [design register](../../notes/design-register.md) and the invariants they touch are in [Boundaries and trust](../design/principles.md).

- **The tenant's processes are Linux processes, and the kernelet supplies their memory through a fault handler on their virtual memory areas** (register D78). A kernelet-built address space entered from a kernel thread is not possible on Linux. Linux keeps ownership of the address-space structure, so the kernel proper's memory management must be re-expressed over Linux's interfaces.
- **The tenant's system calls reach the kernelet through a per-task hook, and Linux mode requires the patch** (register D79). Syscall User Dispatch does not yield an unpatched mode: Linux clears it at every `fork` and `exec`, so only a tenant's first thread is intercepted, and the tenant can reach Linux's own system calls two other ways besides. It is kept as a measured lower bound on interception that goes through user space. Seccomp user notification and ptrace are rejected on measurement.
- **The tenant's process lifecycle is not designed** (register D81), and neither is the handling of the virtual system-call pages.

Five things the Design chapter takes for granted do not hold under a Linux host, and one of them changes how the kernel proper reaches its tenant's memory at all. They are on the [next page](not-as-assumed.md).
