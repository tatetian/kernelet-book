# Containment: stopping a kernelet, and surviving its faults

*Three designs against the two limitations that cost the boundary the most: a kernelet that loops in kernel mode cannot be killed, and a fault in kernelet code takes down whatever task was running it. The chapter being fixed calls the second unanswerable. It is not, and the mechanism that answers it also answers most of the first.*

## Two premises that the tree contradicts

Before the designs, the two sentences they rest on, because both correct [Linux as the host](../linux-mode/index.md).

**A kernel-mode fault does not have to be fatal.** `die()` sets its signal to zero when a registered notifier answers with a stop, and `oops_end()` then returns rather than killing the task. [`register_die_notifier`](https://elixir.bootlin.com/linux/v6.12/source/kernel/notifier.c#L604) is exported. So a module can recognize a fault in text it owns, move the instruction and stack pointers, and resume somewhere of its choosing.

**Except on a machine configured to capture a crash dump.** The very first thing `oops_end()` does is call [`crash_kexec()`](https://elixir.bootlin.com/linux/v6.12/source/kernel/crash_core.c#L89) when the crash test says so, and that test returns true whenever the operator has set the kernel to panic on an oops. With a crash kernel loaded, that call does not return: the machine reboots into the dump kernel before any notifier is consulted. So recovery is conditional on the operator *not* running the default posture of two major distributions. That is a third operator requirement, and it belongs beside the two the conservative mode is pleased to have withdrawn.

**There is something to resume *to*, and at the right moment the task holds nothing.** The chapter rejects a fixup on the grounds that unwinding the faulting task's locks and read-copy-update sections is something Linux cannot do. That is true at service-call depth one, which the design already classifies as a host bug. At depth zero the kernelet holds nothing of the host's, which is the whole point of the depth counter, and the unwinding wanted is the kernelet image's own: it carries the kernel proper's unwinder.

## Safe points by construction {#safe-points}

*Attacks:* termination. *Helps:* both hosts.

The cooperative substitute needs a check, and hand-placed checks are exactly what a runaway kernelet skips, because the loop that does not return to a service call never reaches one. This design has the compiler place them instead. Building the kernel proper and vOSTD with instrumentation at function entry emits one call at the top of every function that survives inlining, and under the position-independent model that call goes indirectly through the image's own global offset table.

That indirection is the design. The endovisor selects what a watched instance does by writing **one word** in that instance's table: a no-op stub when the kernelet is healthy, a check when it is being watched or wound down. No text is patched, which matters because a module may not patch text — the lock that protects it is deliberately not exported — and because the text is shared by every instance of a kind while the table is per instance.

The check earns more than termination. It can test the dying flag, a deadline, and the remaining stack, which turns the stack overflow that would otherwise halt the machine into an ordinary kernelet panic. *Estimated* at 300 to 600 nanoseconds per system call while an instance is watched, and nothing when it is not.

**Verdict.** Promising and cheap, and worth building whatever else is built. But it narrows termination rather than restoring it: a kernelet that is not executing its own instrumented code, because it is spinning in a compiled loop with no calls, is still not stopped.

## The abort trampoline, and revoke {#trampoline}

*Attacks:* both, through one mechanism. *Helps:* Linux mostly; the revoke idea carries.

Three parts, and the third is the one that changes the argument.

**A landing pad** in the endovisor module's own text, not in the kernelet image, deliberately, because the third part unmaps the kernelet's text. It is entered with the stack pointer already restored to the task's entry stack, which the per-task record holds. It abandons the kernelet stack unread, marks the instance dying, and returns up the hook's own path. No kernelet frame is unwound and no kernelet destructor runs, which is the existing decision D35 unchanged.

**Two ways to reach it.** Without a patch, the die notifier above: the handler checks that the faulting instruction lies in some instance's text *and* that the task's service depth is zero, and if both hold it rewrites the two registers and answers with a stop. With a patch, a fourth registrant in the kernel's fixup search, about forty lines, range-based rather than per-instruction, which catches the same faults earlier and without the oops being printed first.

**Revoke, which forces the issue.** The host does not have to wait for a kernelet to fault. It can *cause* one, by unmapping that instance's own text and shooting the translation down on every processor. Every task executing that kernelet then faults at its next instruction fetch, lands in the trampoline, and is contained — including tasks that were parked and wake up later.

The shootdown is not free and is not automatic, which the first draft of this section missed. Unmapping a kernel range clears the entries but defers the invalidation to a lazy purge that may be arbitrarily far away, so a processor holding a cached translation **keeps executing the kernelet** — exactly the runaway the mechanism exists to stop. The range-flush call that would fix it is not exported. The exported substitute is to run a full translation flush on every processor, which works and costs a machine-wide full flush per revocation rather than a range invalidation. That substitution has to be named, and it is the same missing export that the [supervisor alias](whole-mode.md#alias) needs for its own kernel-range invalidation.

That is the part worth taking away, because it is a stronger primitive than the host we wrote has today: it stops a kernelet without the kernelet's cooperation, without a signal, and without waiting for a safe point.

**What it costs, and it is worse than a noisy console.** The report runs before the notifier, and it runs with interrupts disabled while holding a **machine-wide** lock, through a full register dump and a module list written synchronously to the console. That is tens of milliseconds on a serial console, serialized across every processor. A tenant that faults in a loop does not drown the console; it stalls the machine, loses timer ticks and trips the lockup detector. The kernel is also tainted unconditionally on the first one, so a host running kernelets is permanently tainted after its first tenant bug.

So the patch is a functional requirement wherever a tenant can cause repeated faults, not a courtesy. The no-patch route is the right answer for a *bug* and the wrong one for anything a tenant can provoke.

**Verdict.** Promising, and the one to bet on. It restores fault containment at depth zero and the forced half of termination, with one exported symbol and no patch, and the patch that improves it is small and buys a second thing as well.

## Kernelet code gets its own context {#own-context}

*Attacks:* both, structurally. *Helps:* Linux only.

Rather than making a fault or a kill work on the tenant's task, move the kernelet's work off it: the tenant parks in a killable wait and pinned per-virtual-CPU kernel threads do the servicing. A kernel thread can be stopped cooperatively and a parked tenant can be killed, so both limitations soften at once.

It costs a handoff per system call, *estimated* at 1.5 to 3 microseconds against the 39 nanoseconds the measured hook costs, and it recovers neither property outright: a servicing thread that loops is exactly as unkillable as the tenant's task was.

**Verdict.** Not as a default. Its value is a finding rather than a design: the same handoff shape reappears in the whole-mode designs, where it is paid for by something larger than containment.

## What this cluster establishes

The chapter's hardest containment claim was wrong, and the correction is now folded into it. Fault containment at service-call depth zero is available today, for one exported symbol. Forced termination is available too, by revoking a kernelet's own text, which is a mechanism the design did not have on either host. What remains genuinely missing is the ability to stop a kernelet that is neither faulting nor reaching an instrumented point, and only a kill point inside Linux, or a hardware timer, restores that.
