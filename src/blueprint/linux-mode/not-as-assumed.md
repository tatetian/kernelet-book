# Five places where the host does not behave as the design assumed

*Five things the Design chapter takes for granted do not hold when the host is Linux: an invariant, an assumption, a property the boundary owes, a mechanism, and one constraint that comes from the hardware rather than from Linux at all. They are collected here rather than scattered, because together they are the honest measure of what Linux mode costs. Four have an answer — three sketched and not built, one measured; one has none. Each applies to a kernelet's own kernel threads as much as to a tenant's task, which is why they are not on the [previous page](tenant.md).*

## A runaway kernelet cannot be stopped

[Faults, termination and reclamation](../design/faults-and-reclamation.md) requires that a kernelet task be terminable and its stack discarded, and that a kernelet be destroyed without running any of its code. Linux cannot. A kill signal is acted on only where a task returns to user mode, so a task executing in kernel mode cannot be killed there, however long it stays; stopping a kernel thread is cooperative; and on the patched path the kernel proper's code runs *on the tenant's own task, in kernel mode*, exactly where a signal cannot reach it. Whether such a task also *holds* its processor depends on the kernel's preemption setting, which is the operator's choice; that it cannot be killed does not. A kernelet that loops inside the hook is an unkillable task and a destroy that never completes. **Invariant I7, termination, does not hold in Linux mode.** The substitute is cooperative: a check of the dying flag at every service-call boundary, a deadline, and a watchdog. It is weaker, because it needs the kernelet to keep working well enough to notice.

## The kernel stack is a fraction of what the design assumes

The [control half](../design/kernelet-api-control.md) gives a kernelet task a 512 KiB stack, and assumption A3 reserves 64 KiB of headroom for the deepest host path a service call takes. On Linux a kernel stack is 16 KiB, for kernel threads and for the tenant's task alike, and on the patched path a full Linux-compatible kernel's system-call path runs on that stack on top of Linux's own entry frame, with a guard page that turns overflow into a crash. That is a thirty-two-fold mismatch against the stack the design gives a kernelet task, and Linux's whole stack is a quarter of the headroom assumption A3 reserves for the host path alone.

It has an answer, and the technique is Linux's own: the hook switches to a per-task kernelet stack on entry and back on return, which is what Linux does for hardware-interrupt handlers. The current task is found through a per-processor pointer rather than through the stack, so it keeps working; and the task may sleep on the switched stack, since the scheduler saves only the stack pointer. Two costs come with it. Stack-based backtraces do not recognize the range, so an oops inside a kernelet stops at the switch. And the kernel's own stack-validation tooling has to be told about the frame, along with its guard-page reporter: an overflow on a stack Linux does not know about is not diagnosed as a stack overflow at all, and halts the machine rather than killing the task. That is a paragraph of design rather than an unresolved mismatch, and it is written here as such — it is not built. **[unverified]**

## A fault in kernelet code is a Linux oops

The design's second tier of containment is that a fault inside a kernelet kills that kernelet and nothing else ([Faults, termination and reclamation](../design/faults-and-reclamation.md)). It works because the host's fault handler is ours: it recognizes the faulting address as a kernelet's, kills it, and reclaims.

Linux's fault handler is Linux's. A kernel-mode fault in kernelet code is an **oops**: Linux prints a trace and kills the task that was running, which on the patched path is the tenant's own task, holding whatever it held. The machine survives only if it was configured not to panic on an oops, and the kernelet is left half-dead rather than reclaimed.

This page's first draft called it the one item with no answer. It has one, and the [alternatives chapter](../alternatives/index.md) gives it, because the premise here was wrong at the first step: **the fault does not have to be fatal**. `die()` sets its signal to zero when a registered notifier answers `DIE_OOPS` with a stop, and `oops_end()` then returns instead of killing the task ([`arch/x86/kernel/dumpstack.c`](https://elixir.bootlin.com/linux/v6.12/source/arch/x86/kernel/dumpstack.c)); `register_die_notifier` is exported. So a module can recognize a fault in a kernelet's text, rewrite the instruction and stack pointers to a landing pad of its own, and resume. The unwinding this paragraph said Linux has no primitive for is the kernelet image's own: it carries the kernel proper's unwinder.

What remains true is narrower and is still a cost. The oops has already been printed by the time a notifier runs, and the console level is raised without being restored, so a tenant that faults repeatedly can flood the machine's console. The argument for a patch here is therefore about fairness rather than about function.

That is what happens when a kernelet has a bug. The next section is about an access the design expects on every system call that carries a buffer, and it has a different answer.

## Kernelet code cannot touch tenant memory directly

This is the constraint that changes the design, it comes from the hardware rather than from Linux's interfaces, and it was [measured](evidence.md) rather than argued.

Since Broadwell and Zen, x86-64 processors refuse a kernel-mode access to a page marked as user memory unless one flag in the processor's status register is set. Linux's copy routines set it for the length of the copy with the [`stac` and `clac`](https://elixir.bootlin.com/linux/v6.12/source/arch/x86/include/asm/smap.h) instructions and clear it again; that pairing is why they are the only code in Linux that touches user memory. And [`do_user_addr_fault()`](https://elixir.bootlin.com/linux/v6.12/source/arch/x86/mm/fault.c#L1257) checks this **first**, before it looks the address up in the process's areas and before it searches for a fixup, reporting the access as a bad kernel pointer.

**Asterinas does not enable the check and Linux does.** The framework sets five bits in the control register and not that one, and nothing in its tree emits the bracketing instructions. So the kernel proper's copy routines work on one host and fault on the other, and neither the API nor its [taxonomy](../design/virtualizing-ostd/index.md) says a word about it. That is a host property leaking through an interface that claims to be host-independent, and it is the clearest thing porting found.

The experiment ran six cases ([evidence](evidence.md)), and three of them decide the rule.

Reading the same value through **the supplier's own kernel alias needed no bracket at all**. The frame is the kernelet's, it reaches it through the linear map as it reaches every other frame it owns, and that alias is not marked as user memory, so there is nothing to refuse. And a **bracketed** read of a **bad** address ended the task anyway, while the same read with a fixup entry recovered — which works there only because the code is in a module and Linux searches the loaded modules' tables. A kernelet is not a module and cannot become one without giving up the shared text.

The first says there is a way. The second says bracketing is not it: the kernel proper's copies are *fallible* by contract, their job is to return an error for a bad address, and bracketing cannot deliver that contract on Linux.

**So the rule is an addressing rule, not a crossing.** The kernel proper reaches its tenant's memory through its own alias of the frames it supplied, never through the tenant's virtual address. That is decision D82, and it is the same technique the [zero-copy design](../design/zero-copy-io.md) already uses for device buffers.

It costs the kernel proper nothing in source. The copy routines belong to the framework, not to the kernel above it, so the rule is implemented inside vOSTD: the kernel proper still calls `VmReader` and `VmWriter` and does not know which host it is on. This is the taxonomy working as designed — a virtualized item with a second body — rather than a breach of it.

The rule needs a translation, and its direction matters. A system call arrives with a tenant **virtual address**, so what is wanted is address to frame. vOSTD does not have to derive that from Linux: its own fault handler is what supplied each frame, so it can record the pair as it hands the frame over. The map is built by construction rather than shadowed.

Two things about that map are open, and the second is the more serious.

**A miss is structural, not exotic.** vOSTD holds an alias for every frame *it* supplied and for nothing else. A tenant's address space also holds the stub the runtime maps, Linux's own virtual system-call pages, and whatever Linux populated itself, since Linux keeps the address-space structure. Each of those is a miss, and a miss costs a crossing. How often that happens under a real workload is unmeasured. **[unverified]**

**A stale entry is worse than a miss.** Linux tears a mapping down without consulting the handler that supplied it, which [the previous page](tenant.md) records and calls a design this chapter does not have. Under the alias rule that gap stops being untidy and becomes unsound: an entry that outlives its mapping does not miss, it **resolves**. A miss is safe — it faults, it costs a crossing, the design notices. A stale hit is silent: the kernel proper writes data the tenant will never see, or reads a frame that has gone back to the host and on to another kernelet. The alias rule is what makes that reachable, because before it the hardware would have refused the access outright.

Linux's answer to exactly this problem is the [MMU-notifier interface](https://elixir.bootlin.com/linux/v6.12/source/include/linux/mmu_notifier.h), which is exported and which KVM uses to keep shadow page tables coherent with a host address space. One caveat belongs with it, because the chapter would otherwise promise something it cannot deliver: [`mmu_interval_read_begin()`](https://elixir.bootlin.com/linux/v6.12/source/mm/mmu_notifier.c#L249) waits on a queue when an invalidation is in flight, so it can sleep. That is acceptable on a system-call path and not acceptable inside the non-sleeping lock this rule also requires, nor on the futex path, which Linux runs with faults disabled. A callback alone is not enough, and the difference matters to whoever builds this: being told that a range is going away does not stop a copy already in flight, where one processor is between the lookup and the write through the alias while another tears the mapping down. So the mechanism is not the bare callback but the **sequence protocol** Linux ships with it — take the sequence number before the lookup, copy, re-check before committing, retry if it moved. All three calls it needs are exported.

Two constraints come with it, and both belong with the rule rather than in a footnote:

- The notifier machinery is a build option that nothing selects on its own; a kernel with virtualization support has it, and Linux mode joins the virtual system-call page in requiring it of the build rather than assuming it.
- The invalidation callback may be invoked in a context where it **must not sleep**, and part of the machinery runs under Linux's own page-table locks. So whatever lock protects the address-to-frame map has to be a non-sleeping one, and no crossing into the kernelet may happen while it is held — which constrains the lookup path too, since it takes the same lock.

**Closing this is a precondition of the rule, not a detail of it.** **[unverified]**

One consequence for the interface, in the rule's favor. A Linux-compatible kernel must perform an *atomic* compare-and-exchange on tenant memory, because that is what a futex is; a copy routine cannot express it, and Linux keeps separate internal primitives for it. Through the alias it is an ordinary atomic on a kernel address, so the problem does not arise.

## The per-CPU model has no Linux counterpart

vOSTD gives each kernelet one replica of its per-CPU data per virtual CPU, and finds the right replica by the virtual-CPU number in the host's CPU slot ([Tasks](../design/virtualizing-ostd/tasks.md)). Forming that address is safe only if the task cannot migrate in the middle of it, which the design arranges with a preemption count in the task record that the host honors.

Linux honors no such count. Worse, on the patched path the kernel proper runs on the **tenant's own task**, which is an ordinary Linux task with no virtual-CPU binding and nothing pinning it. So the selector can change under the code. This reaches every per-CPU access, every lock taken with preemption disabled, and the read side of read-copy-update, which is most of the kernel.

Migration is the smaller half. The worse case is two selectors that agree when they must not: the replica is chosen by *virtual* CPU, and a tenant can have more runnable tasks inside serviced calls than its kernelet has virtual CPUs, on different processors at the same instant. Two of them then index the same replica concurrently, which no preemption count and no migration hold prevents, on state the kernel proper is entitled to treat as uncontended.

The repair has three parts and none is designed here, and the first is not always available. `disable_preempt` must become an actual host preemption disable — except that on a kernel built without preemption, which is what the chapter's own experiments ran on, the host's preemption disable compiles to a compiler barrier and its preemptible-state accessor to the literal zero. So the repair's first part is a no-op on exactly the configuration a density-minded operator is most likely to run. The tenant's task must be held on one processor for the duration of a serviced call, by the primitive that forbids migration rather than by an affinity mask, which is a different thing with a scheduler cost of its own. And the virtual-CPU assignment must be injective at every instant — at most one task inside a serviced call per virtual CPU — which is a scheduling constraint, not a lock.

## What this page decides

- **Invariant I7, termination, does not hold** (register D81). The substitute is a cooperative check at every service-call boundary, with a deadline and a watchdog, and it needs the kernelet to be working well enough to notice.
- **Fault containment does not hold either**, for a reason independent of termination: a fault in kernelet code is a Linux oops on whichever task was running.
- **The kernel proper reaches its tenant's memory through vOSTD's own alias of the frames it granted, never through the tenant's virtual address** (register D82). Forced by the hardware, measured, and cheaper than a crossing per copy. What is open is the address-to-frame map: how often it misses, and what keeps it true when Linux takes a mapping away.
- **A kernelet task runs on a stack the hook switches to on entry** (register D84), because Linux's own is a thirty-second of what the design gives a kernelet task. What remains unverified about it is assumption A20.
- **The per-CPU replica selector needs a real host preemption disable, a migration hold, and an injective virtual-CPU assignment.** Not designed here.
