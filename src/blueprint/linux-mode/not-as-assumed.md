# Five places where Linux does not behave as the design assumed

*The Design chapter states eight invariants and rests on a list of numbered assumptions. Five of them do not survive a Linux host, and they are collected here rather than scattered, because together they are the honest measure of what Linux mode costs. Two have answers, sketched below and not built. Three do not, and are recorded as the design rather than as a defect to be fixed later. Each applies to a kernelet's own kernel threads as much as to a tenant's task, which is why they are not on the [previous page](tenant.md).*

## A runaway kernelet cannot be stopped

[Faults, termination and reclamation](../design/faults-and-reclamation.md) requires that a kernelet task be terminable and its stack discarded, and that a kernelet be destroyed without running any of its code. Linux cannot. A kill signal is acted on only where a task returns to user mode, so a task executing in kernel mode cannot be killed there, however long it stays; stopping a kernel thread is cooperative; and on the patched path the kernel proper's code runs *on the tenant's own task, in kernel mode*, exactly where a signal cannot reach it. Whether such a task also *holds* its processor depends on the kernel's preemption setting, which is the operator's choice; that it cannot be killed does not. A kernelet that loops inside the hook is an unkillable task and a destroy that never completes. **Invariant I7, termination, does not hold in Linux mode.** The substitute is cooperative: a check of the dying flag at every service-call boundary, a deadline, and a watchdog. It is weaker, because it needs the kernelet to keep working well enough to notice.

## The kernel stack is a fraction of what the design assumes

The [control half](../design/kernelet-api-control.md) gives a kernelet task a 512 KiB stack, and assumption A3 reserves 64 KiB of headroom for the deepest host path a service call takes. On Linux a kernel stack is 16 KiB, for kernel threads and for the tenant's task alike, and on the patched path a full Linux-compatible kernel's system-call path runs on that stack on top of Linux's own entry frame, with a guard page that turns overflow into a crash. That is a thirty-two-fold mismatch against the design's own assumption.

It has an answer, and the technique is Linux's own: the hook switches to a per-task kernelet stack on entry and back on return, which is what Linux does for hardware-interrupt handlers. The current task is found through a per-processor pointer rather than through the stack, so it keeps working; and the task may sleep on the switched stack, since the scheduler saves only the stack pointer. Two costs come with it. Stack-based backtraces do not recognize the range, so an oops inside a kernelet stops at the switch. And the kernel's own stack-validation tooling has to be told about the frame. That is a paragraph of design rather than an unresolved mismatch, and it is written here as such — it is not built. **[unverified]**

## A fault in kernelet code is a Linux oops

The design's second tier of containment is that a fault inside a kernelet kills that kernelet and nothing else ([Faults, termination and reclamation](../design/faults-and-reclamation.md)). It works because the host's fault handler is ours: it recognizes the faulting address as a kernelet's, kills it, and reclaims.

Linux's fault handler is Linux's. A kernel-mode fault in kernelet code is an **oops**: Linux prints a trace and kills the task that was running, which on the patched path is the tenant's own task, holding whatever it held. The machine survives only if it was configured not to panic on an oops, and the kernelet is left half-dead rather than reclaimed.

## Kernelet code cannot touch tenant memory at all

This is the hardest constraint in the chapter, it comes from the hardware rather than from Linux's interfaces, and no export addresses it.

Since Broadwell and Zen, x86-64 processors refuse a kernel-mode access to a user-mode address unless one flag in the processor's own status register is set. Linux's copy routines set it for the length of the copy and clear it again; that pairing is why they are the only code allowed to touch user memory. Anything else faults, and Linux's fault handler checks this **first**, before it looks the address up in the process's areas and before it searches for a fixup: a supervisor access with the flag clear is reported as a bad kernel pointer and the machine takes an oops.

A kernelet's code is compiled by the ordinary Rust toolchain and emits a bare copy. So the first byte the kernel proper reads from or writes to its tenant ends the task, whether or not the page is present, mapped or writable.

There is no way to hold the flag open across the kernelet's work. It lives in the live status register, it is not preserved across a context switch, and a kernelet sleeps, takes locks and yields — so opening it would leak the permission into unrelated tasks. Linux confines its own such regions to straight-line code for exactly this reason.

**So every access to tenant memory must be performed by host code.** That is decision D82, and it is forced rather than chosen. `VmReader` and `VmWriter` over tenant addresses become service calls, and the host performs them with Linux's own copy routine, which brackets the access correctly and which Linux's fault handler *will* recover if the page is absent. The cost is a crossing per copy where today there is an instruction, on the path every system call that passes a buffer takes. It is unmeasured, and it is the largest performance question Linux mode raises. **[unverified]**

The exception table matters only after that. On the error path — a genuinely bad address — Linux searches its own table and those of loaded modules, and a kernelet is not a module, so a fixup in the kernelet image is never found. Routing the access through the host's copy routine settles that too, since the entry Linux finds is its own.

## The per-CPU model has no Linux counterpart

vOSTD gives each kernelet one replica of its per-CPU data per virtual CPU, and finds the right replica by the virtual-CPU number in the host's CPU slot ([Tasks](../design/virtualizing-ostd/tasks.md)). Forming that address is safe only if the task cannot migrate in the middle of it, which the design arranges with a preemption count in the task record that the host honors.

Linux honors no such count. Worse, on the patched path the kernel proper runs on the **tenant's own task**, which is an ordinary Linux task with no virtual-CPU binding and nothing pinning it. So the selector can change under the code. This reaches every per-CPU access, every lock taken with preemption disabled, and the read side of read-copy-update, which is most of the kernel.

The repair is not deep but it is real: `disable_preempt` must become an actual host preemption disable, which any module may use, and the tenant's task must be held on one processor for the duration of a serviced call — by the primitive that forbids migration, not by setting an affinity mask, which is a different thing with a scheduler cost of its own. Neither is designed here.

## What this page decides

- **Invariant I7, termination, does not hold** (register D81). The substitute is a cooperative check at every service-call boundary, with a deadline and a watchdog, and it needs the kernelet to be working well enough to notice.
- **Fault containment does not hold either**, for a reason independent of termination: a fault in kernelet code is a Linux oops on whichever task was running.
- **Every access to tenant memory is a service call the host performs** (register D82). Forced by the hardware, unmeasured, and the chapter's largest performance question.
- **A kernelet task runs on a switched stack** (assumption A20), because Linux's own is a thirty-second of what the design reserves.
- **The per-CPU replica selector needs a real host preemption disable and a migration hold** on the tenant's task. Not designed here.
