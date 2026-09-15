# The tenant: user mode and system calls

*The hardest part of Linux mode. A kernelet must run its tenant's programs and answer their system calls, and Linux gives an out-of-tree component no way to do either directly. This page works through what Linux does offer, measures the candidates, and reaches a conclusion the first draft of this chapter got wrong: the optional patch is not a performance option. It is what decides whether the kernelet is the tenant's boundary at all.*

## Why this is hard

In Asterinas mode the answer is short. vOSTD calls `user_run`, the host switches to the tenant's address space and returns to user mode, and when the tenant makes a system call the host returns from `user_run` with the reason ([User mode](../design/virtualizing-ostd/user-mode.md)). The host is ours; we wrote the entry path.

On Linux neither half of that is available.

**A kernel thread cannot return to user mode.** A kernel thread is dispatched at creation to a function that never leaves the kernel, and it has no saved user register state to return to. Borrowing a process's address space with `kthread_use_mm()` deliberately does not change that: it lets the thread read and write that process's memory, not become it.

**No module can intercept a task's system calls.** Linux diverts a call in three places — syscall user dispatch, ptrace, seccomp — and all three are driven from user space. A tracing probe can watch a call, or change its number, but nothing in the kernel can *answer* one on a module's behalf. On x86-64 there is not even a table to patch: the dispatch is a `switch` compiled into the entry path, and the old system-call table survives only for tracing.

## The shape of the answer

Since the kernelet cannot create a user-mode context, it borrows one: **the tenant's processes are Linux processes**. Linux schedules them, enters and leaves them, and handles their traps. What changes is who answers their system calls and who supplies their memory.

Memory is the easier half and needs no patch. The endovisor gives the tenant's address space a **virtual memory area whose fault handler is the kernelet's**, so when the tenant touches an address, Linux calls that handler and the kernelet supplies a frame from its own grant.

Two cautions, because "the kernelet owns its tenant's memory" is too strong for what this buys. Linux still owns the address-space *structure* — the list of areas, and therefore `mmap`, `mprotect`, `mremap`, reclaim and copy-on-write — so the kernel proper's memory management must be re-expressed over Linux's interfaces rather than carried across unchanged. And pages handed out this way carry no memory-cgroup charge unless the endovisor adds one, so a tenant's memory escapes the host's accounting by default.

System calls are the hard half.

## The four candidates, measured

Two machines were used, and the tables are kept apart so that nothing is compared across them. Guest figures are medians of five runs.

Measured in the **guest**, where a call Linux services itself costs 44 ns:

| mechanism | median | overhead | needs a patch |
|---|---|---|---|
| a call Linux services itself | 44 ns | — | — |
| **Syscall User Dispatch** | 929 ns | **+885 ns** | no |
| **per-task hook** | 39 ns | below the noise | yes |

Measured on the **build host**, where the floor is 485 ns:

| mechanism | per call | overhead |
|---|---|---|
| Syscall User Dispatch | 1,887 ns | +1,405 ns |
| seccomp user notification | 5,721 ns | +5,231 ns |
| `ptrace(PTRACE_SYSEMU)` | 8,221 ns | +7,736 ns |

The hook measures *faster* than a bare `getppid` because the servicer used for the measurement returns a constant while `getppid` does real work. So the number does not say a kernelet is free. It says that **the hook adds nothing measurable to Linux's entry path**: reaching a kernelet costs about what reaching Linux's own handler costs, and the kernelet's actual work is the kernel proper's code, identical on both hosts.

**Read the overheads, not the ratios.** The guest is a minimal kernel with no speculative-execution mitigations, no page-table isolation and no indirect-branch thunks, so its floor is ten times lower than a production host's and any ratio taken against it flatters. Syscall User Dispatch costs +885 ns in the guest and +1,405 ns on the mitigated host: the same order, and that is as much as this supports. On a production kernel both paths grow — dispatch pays two more ring transitions, which page-table isolation makes worse, and the hook's indirect call becomes a thunk — and which grows faster was **not measured**. **[unverified]**

Two candidates fall away on measurement. Both seccomp user notification and ptrace put the answer in a *different process*, so each tenant call becomes a pair of context switches to a supervisor and back. On the same machine they cost three to four times what Syscall User Dispatch costs.

One clarification, since it is easy to get wrong: **gVisor does not use seccomp user notification.** Its current platform, systrap, uses a seccomp filter that *traps*, raising `SIGSYS` in the calling thread, with a stub handler that reaches gVisor's kernel through shared memory. That is the same shape as Syscall User Dispatch, not the shape rejected here. gVisor has spent years optimizing that path; none of its techniques was tried here, and they are the obvious thing to aim at the +885 ns.

## The no-patch path, and the hole in it

Syscall User Dispatch lets a process ask Linux to stop executing its system calls and raise a signal instead, with one byte in the process's own memory deciding whether the diversion is on.

The sandbox is set up like this. The kernelet runtime starts the tenant's first process with a small **stub** mapped into it. The range handed to Linux is the range that is *exempt*, so the stub goes **inside** it and the stub's own calls run normally while everything outside traps. The stub arms dispatch and sets the selector byte to *block*. From then on: the tenant executes a system call; Linux raises `SIGSYS` instead of running it; the stub's handler makes one call into the endovisor carrying the register set; the kernelet services it; the stub writes the result into the signal frame and returns; the tenant resumes.

Two honest notes about the 929 ns. The program that produced it ran with **no** exempt range and a handler that filled in a result directly, so it measures the signal delivery and return — steps one and four — and not the call into the endovisor in between. A real stub adds at least one more kernel entry, so 929 ns is a floor.

Now the part the first draft of this page got wrong.

**On this path the tenant can reach Linux's own system calls.** Two ways, neither exotic. The selector byte lives in the tenant's memory, so the tenant can store *allow* and make an ordinary call. Or it can jump to the `syscall` instruction inside the stub, which is in the exempt range by construction, with registers of its own choosing.

So on the no-patch path the kernelet is **not** the tenant's boundary. What confines the tenant is Linux's own machinery: an unprivileged user id, a set of namespaces, and a seccomp filter — which is the container boundary this work exists to improve on. The Paper opens by observing that a tenant which finds a global the namespaces do not partition has found its neighbors; on this path that sentence applies to a kernelet's tenant too.

Two things narrow the hole without closing it. Mapping the selector page read-only to the tenant stops the store but not the jump. A seccomp filter over the tenant turns "the whole Linux system-call interface" into "whatever the filter allows", which is what gVisor does and is worth doing. Neither makes the kernelet the boundary.

## The patched path, and why it is the real one

The patch adds one field to the task structure and one branch at the top of the system-call path: if this task has a kernelet, call it instead of dispatching. There is no selector for the tenant to flip and no exempt range to jump into. **The kernelet becomes the tenant's only system-call surface**, which is what the design claims everywhere else and what the no-patch path cannot deliver.

That is the argument for the patch. The twenty-four-fold difference is real but secondary, and the first draft led with it, which was a mistake: it made a security mechanism look like an optimization.

**The patch as first measured had two defects, both found in review.** It returned a value meaning *leave through the slow exit path*, which sent every serviced call out the expensive way and skipped the checks that would have allowed the fast one; that, and not the hook, was most of the cost first reported. And it did not test for the marker meaning *an earlier stage already answered this call*, so attaching a kernelet would have overridden that task's seccomp verdict. Both are fixed and the numbers above are from the fixed version.

**What is still wrong with it** is recorded rather than repaired, because it changes the size of the ask:

- **Only one of four entry points is hooked.** A 64-bit process on a kernel built with 32-bit compatibility — which production kernels usually are — can enter through the legacy interrupt or the fast 32-bit path, neither of which passes the hook. Its call is then serviced by Linux, with the tenant's own credentials, invisibly to the kernelet. That is a complete escape, and the guest used here had compatibility compiled out, so it could not appear in the measurement.
- **No lifetime management.** `fork` copies the two fields into the child, nothing clears them when a task exits, and nothing takes a reference on the module, so unloading it can leave a task pointing into freed memory.
- **The return-value convention is unstated.** Several negative values mean *restart this call* to Linux's signal machinery; a kernelet returning one would have its call silently re-executed.

**Would it be accepted upstream?** No, not as posted. A version with a chance would be framed as a generalization of Syscall User Dispatch — an in-kernel dispatch target instead of a signal — gated behind a configuration option, with an in-tree user and the lifetime rules worked out.

## What is missing entirely

Two gaps larger than anything above, stated because the chapter would be dishonest without them.

**Process lifecycle.** The hook's shape — take a register set, return a value — cannot express `fork`, which returns twice; `execve`, which replaces the address space and the register file; or the return from a signal handler, which restores a saved frame. Only Linux can create a Linux task, and the functions that do so are not available to a module. How a kernelet's processes map onto Linux tasks, and who owns the tenant's signals, is **not designed here**, and it is the largest open item in this chapter.

**The virtual system-call page.** Some calls — reading the clock, asking which processor you are on — are served from a page Linux maps into every process, without entering the kernel at all. Neither dispatch nor the hook sees them, so a tenant would read the *host's* clock rather than its kernelet's. The endovisor must unmap that page from its tenants or supply its own.

## Two things Linux will not do, which the design assumed

**A runaway kernelet cannot be stopped.** [Faults, termination and reclamation](../design/faults-and-reclamation.md) requires that a kernelet task be terminable and its stack discarded, and that a kernelet be destroyed without running any of its code. Linux cannot: a task in kernel mode runs until it returns to user mode of its own accord, stopping a kernel thread is cooperative, and on the patched path the kernel proper's code runs *on the tenant's own task, in kernel mode*, where a kill signal cannot reach it. A kernelet that loops inside the hook is an unkillable task and a destroy that never completes. **Invariant I7, fault containment, does not hold in Linux mode.** The substitute is cooperative — a check of the dying flag at every service-call boundary, a deadline, a watchdog — and it is weaker, because it needs the kernelet to keep working well enough to notice.

**The kernel stack is a fraction of what the design assumes.** The [control half](../design/kernelet-api-control.md) gives a kernelet task a 512 KiB stack, and assumption A3 reserves 64 KiB of headroom for the deepest host path a service call takes. On Linux a kernel stack is 16 KiB, for kernel threads and for the tenant's task alike, and on the patched path a full Linux-compatible kernel's system-call path runs on that stack on top of Linux's own entry frame, with a guard page that turns overflow into a crash. That is a thirty-two-fold mismatch against the design's own assumption, and this chapter does not resolve it.

## What this page decides

- **The tenant's processes are Linux processes, and the kernelet supplies their memory through a fault handler on their virtual memory areas** (register D78). A kernelet-built address space entered from a kernel thread is not possible on Linux. Linux keeps ownership of the address-space structure, so the kernel proper's memory management must be re-expressed over Linux's interfaces.
- **The tenant's system calls reach the kernelet through a per-task hook where the patch is accepted, and through Syscall User Dispatch where it is not** (register D79). The patch is a security mechanism, not an optimization: without it the tenant can reach Linux's system calls and the effective boundary is the container's. Seccomp user notification and ptrace are rejected on measurement.
- **Invariant I7 does not hold in Linux mode, and the tenant's process lifecycle is not designed** (register D81). Both are recorded, not solved.
