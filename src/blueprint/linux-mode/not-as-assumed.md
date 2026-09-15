# Five places where Linux does not behave as the design assumed

*Five things the Design chapter takes for granted do not hold when the host is Linux: an invariant, an assumption, a property the boundary owes, a mechanism, and one constraint that comes from the hardware rather than from Linux at all. They are collected here rather than scattered, because together they are the honest measure of what Linux mode costs. Four have an answer sketched below and not built; one has none. Each applies to a kernelet's own kernel threads as much as to a tenant's task, which is why they are not on the [previous page](tenant.md).*

## A runaway kernelet cannot be stopped

[Faults, termination and reclamation](../design/faults-and-reclamation.md) requires that a kernelet task be terminable and its stack discarded, and that a kernelet be destroyed without running any of its code. Linux cannot. A kill signal is acted on only where a task returns to user mode, so a task executing in kernel mode cannot be killed there, however long it stays; stopping a kernel thread is cooperative; and on the patched path the kernel proper's code runs *on the tenant's own task, in kernel mode*, exactly where a signal cannot reach it. Whether such a task also *holds* its processor depends on the kernel's preemption setting, which is the operator's choice; that it cannot be killed does not. A kernelet that loops inside the hook is an unkillable task and a destroy that never completes. **Invariant I7, termination, does not hold in Linux mode.** The substitute is cooperative: a check of the dying flag at every service-call boundary, a deadline, and a watchdog. It is weaker, because it needs the kernelet to keep working well enough to notice.

## The kernel stack is a fraction of what the design assumes

The [control half](../design/kernelet-api-control.md) gives a kernelet task a 512 KiB stack, and assumption A3 reserves 64 KiB of headroom for the deepest host path a service call takes. On Linux a kernel stack is 16 KiB, for kernel threads and for the tenant's task alike, and on the patched path a full Linux-compatible kernel's system-call path runs on that stack on top of Linux's own entry frame, with a guard page that turns overflow into a crash. That is a thirty-two-fold mismatch against the stack the design gives a kernelet task, and Linux's whole stack is a quarter of the headroom assumption A3 reserves for the host path alone.

It has an answer, and the technique is Linux's own: the hook switches to a per-task kernelet stack on entry and back on return, which is what Linux does for hardware-interrupt handlers. The current task is found through a per-processor pointer rather than through the stack, so it keeps working; and the task may sleep on the switched stack, since the scheduler saves only the stack pointer. Two costs come with it. Stack-based backtraces do not recognize the range, so an oops inside a kernelet stops at the switch. And the kernel's own stack-validation tooling has to be told about the frame. That is a paragraph of design rather than an unresolved mismatch, and it is written here as such — it is not built. **[unverified]**

## A fault in kernelet code is a Linux oops

The design's second tier of containment is that a fault inside a kernelet kills that kernelet and nothing else ([Faults, termination and reclamation](../design/faults-and-reclamation.md)). It works because the host's fault handler is ours: it recognizes the faulting address as a kernelet's, kills it, and reclaims.

Linux's fault handler is Linux's. A kernel-mode fault in kernelet code is an **oops**: Linux prints a trace and kills the task that was running, which on the patched path is the tenant's own task, holding whatever it held. The machine survives only if it was configured not to panic on an oops, and the kernelet is left half-dead rather than reclaimed.

This is the one item on this page with no answer, and the chapter does not propose a patch for it. It could: Linux already consults three registrants for a fixup and a fourth would be a small change. But a fixup for a bug buys nothing, because there is nothing to resume to, and the containment the design wants — end this kernelet, reclaim its memory, let the machine continue — would mean unwinding whatever the faulting task held: locks, read-copy-update sections, the address-space lock it took on the way in. Linux has no primitive for that and the absence is not an oversight. Asking for one would be asking a monolithic kernel for a hypervisor's recovery semantics. So this is recorded as a property Linux mode does not have.

That is what happens when a kernelet has a bug. The next section is about a fault the design expects on every system call that carries a buffer, and it has a different answer.

## Kernelet code cannot touch tenant memory directly

This is the constraint that changes the design, it comes from the hardware rather than from Linux's interfaces, and it was [measured](evidence.md) rather than argued.

Since Broadwell and Zen, x86-64 processors refuse a kernel-mode access to a page marked as user memory unless one flag in the processor's status register is set. Linux's copy routines set it for the length of the copy with the [`stac` and `clac`](https://elixir.bootlin.com/linux/v6.12/source/arch/x86/include/asm/smap.h) instructions and clear it again; that pairing is why they are the only code Linux allows to touch user memory. And [`do_user_addr_fault()`](https://elixir.bootlin.com/linux/v6.12/source/arch/x86/mm/fault.c#L1257) checks this **first**, before it looks the address up in the process's areas and before it searches for a fixup, reporting the access as a bad kernel pointer.

**Asterinas does not enable the check and Linux does.** The framework sets five bits in the control register and not that one, and nothing in its tree emits the bracketing instructions. So the kernel proper's copy routines work on one host and fault on the other, and neither the API nor its [taxonomy](../design/virtualizing-ostd/index.md) says a word about it. That is a host property leaking through an interface that claims to be host-independent, and it is the clearest thing porting found.

The experiment ran four cases in the guest, and the result is narrower than "host code must do it":

- A bare read of a tenant address **oopsed**, on a page that was present, mapped and writable. The constraint is not about faulting pages in.
- The same read **succeeded** when the module bracketed it itself. Those are kernel-mode instructions and a kernelet runs in kernel mode, so nothing stops it from doing what Linux does.
- Reading the same value through **the supplier's own kernel alias succeeded with no bracket at all**. The frame is the kernelet's, it reaches it through the linear map as it reaches every other frame it owns, and the alias is not marked as user memory, so there is nothing to refuse.
- A bracketed read of a **bad** address oopsed anyway. The bracket gets past the hardware check, the fault reaches the fixup search, and a fixup in the kernelet image is never found, because Linux searches its own table and the loaded modules' and a kernelet is not a module.

The last case is the one that decides it. The kernel proper's copies are *fallible*: their contract is to return an error for a bad address, and bracketing cannot deliver that contract on Linux.

**So the rule is an addressing rule, not a crossing.** The kernel proper reaches its tenant's memory through its own alias of the frames it supplied, never through the tenant's virtual address. It supplied every one of them out of its own grant, and it already keeps the frame-to-mapping index that assumption A21 requires for revocation, so the translation is a lookup it can afford. That is decision D82, and it is the same technique the [zero-copy design](../design/zero-copy-io.md) already uses for device buffers.

A crossing is needed only on a **miss** — an address the kernelet has no alias for, because it never supplied one or because Linux took the mapping away. That is a fault, which costs a crossing anyway, rather than a cost on every copy. How often a miss happens is the open question, and it is a much smaller one than the chapter carried before the experiment. **[unverified]**

One consequence for the interface. A Linux-compatible kernel must perform an *atomic* compare-and-exchange on tenant memory, because that is what a futex is; a copy routine cannot express it, and Linux keeps separate internal primitives for it. Through the alias the atomic is an ordinary atomic on a kernel address, so the problem does not arise — which is a second reason to prefer the alias rule over a service call.

## The per-CPU model has no Linux counterpart

vOSTD gives each kernelet one replica of its per-CPU data per virtual CPU, and finds the right replica by the virtual-CPU number in the host's CPU slot ([Tasks](../design/virtualizing-ostd/tasks.md)). Forming that address is safe only if the task cannot migrate in the middle of it, which the design arranges with a preemption count in the task record that the host honors.

Linux honors no such count. Worse, on the patched path the kernel proper runs on the **tenant's own task**, which is an ordinary Linux task with no virtual-CPU binding and nothing pinning it. So the selector can change under the code. This reaches every per-CPU access, every lock taken with preemption disabled, and the read side of read-copy-update, which is most of the kernel.

Migration is the smaller half. The worse case is two selectors that agree when they must not: the replica is chosen by *virtual* CPU, and a tenant can have more runnable tasks inside serviced calls than its kernelet has virtual CPUs, on different processors at the same instant. Two of them then index the same replica concurrently, which no preemption count and no migration hold prevents, on state the kernel proper is entitled to treat as uncontended.

The repair has three parts and none is designed here. `disable_preempt` must become an actual host preemption disable, which any module may use. The tenant's task must be held on one processor for the duration of a serviced call, by the primitive that forbids migration rather than by an affinity mask, which is a different thing with a scheduler cost of its own. And the virtual-CPU assignment must be injective at every instant — at most one task inside a serviced call per virtual CPU — which is a scheduling constraint, not a lock.

## What this page decides

- **Invariant I7, termination, does not hold** (register D81). The substitute is a cooperative check at every service-call boundary, with a deadline and a watchdog, and it needs the kernelet to be working well enough to notice.
- **Fault containment does not hold either**, for a reason independent of termination: a fault in kernelet code is a Linux oops on whichever task was running.
- **Every access to tenant memory is a service call the host performs** (register D82). Forced by the hardware, unmeasured, and the chapter's largest performance question.
- **A kernelet task runs on a stack the hook switches to on entry** (register D84), because Linux's own is a thirty-second of what the design gives a kernelet task. What remains unverified about it is assumption A20.
- **The per-CPU replica selector needs a real host preemption disable, a migration hold, and an injective virtual-CPU assignment.** Not designed here.
