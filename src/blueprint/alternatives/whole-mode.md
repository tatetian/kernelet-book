# Whole modes

*The first wave fixed limitations one at a time. Fixes interact, so the second wave builds whole alternative modes: coherent answers to every limitation at once, with their trades made deliberately. Two of them deliberately give up a property the book treats as settled. One is deliberately boring, and it is the one to beat.*

## What every one of them had to answer first

The coordinator found a gap that no first-wave design inherited an answer to, and required each whole mode to close it before anything else.

A tenant enters its kernelet three ways, not one: by a system call, which the patch covers; by a **fault**, which the area's fault handler already gives us; and by Linux **delivering a signal** on the tenant's task, which writes a frame onto the tenant's stack and moves its instruction pointer behind the kernelet's back. A synchronous exception on the tenant's own instruction is a fourth, and the chapter counts none of them as entries.

The obvious answer is wrong, and it is wrong in the same way in every first-wave design that reached for it. Blocking the signals does not stop them: Linux **unblocks** a forced signal and resets its disposition to the default before delivering it, so blocking converts a trap into a kill. The answer is to **redirect rather than block** — install a handler that runs inside the tenant and re-enters the kernelet — and it costs no patch lines at all.

## The conservative restoration {#conservative}

*Gives up nothing. Helps Linux; two of its parts help both hosts.*

The smallest coherent mode that restores all three properties, assembled from the first wave's best parts: one gate in the generic entry layer, the kernelet as a program loader with `clone` declined to Linux, the model page table for tenant memory, the die notifier and revoke for containment, the seat for per-processor soundness, section-indexed metadata for density, and control-group membership for accounting.

What makes it interesting is not the mechanism but the ledger, because it asks Linux for **less** than the chapter asks today and delivers more.

| ask | the chapter today | this mode |
|---|---|---|
| entry-path patch | about 25 lines, one architecture, one of four entries | about 15 lines, the generic layer, every entry on four architectures |
| `set_memory_rox`, `set_memory_rw` | required | required |
| `set_memory_ro` | wanted | wanted, for the metadata guard |
| `get_vm_area` with `init_mm` | wanted | **withdrawn**: section-indexed metadata and a reserved pool make the region dense |
| notifier machinery as a build option | required | **withdrawn**: there is no sequence protocol to run |
| a boot setting | required | **withdrawn**: a seccomp filter replaces it |
| everything else | — | already exported |

And the properties: safety **restored**, with the residue being Linux's own trusted base; fault containment **narrowed to depth zero**, which is the same standing it has on the host we wrote; termination **restored at depth zero** by revoking a kernelet's text rather than by asking it to cooperate; fairness **narrowed**, with an irreducible residue of host work that a tenant induces and Linux will not charge to it.

**What it costs, and the thing that could kill it.** The model page table's cursor lock and the seat's replica lock sit on the same hot path and multiply. No first-wave agent saw that, because each saw one cluster. It is measurable on the existing prototype and has not been measured.

**Verdict.** Promising, and boring on purpose. Strictly less asked, strictly more delivered. This is the design to beat.

## The supervisor alias {#alias}

*Gives up nothing headline; adds one patch and argues it is nearly free. Helps **both hosts**.*

Every tenant access becomes `tenant address + alias base`, through a kernel-half entry that points at the *same* lower tables with the user bit cleared and the no-execute bit set. The hardware's rule is that the effective user bit is the AND across levels, so those pages become supervisor-only through that path and stay exactly as they were through the tenant's own.

**This was built and run, and it works.** In the guest, with the check enabled, a bare kernel-mode read through the alias returned the tenant's value, while the same read of the same frame through the tenant's own address, on the same task in the same run, took a fault and killed the child. The walk printed the spliced entry as supervisor-only with every level below it unchanged, which is the rule observed rather than inferred.

The cost was measured too, and it is the number that makes the design: **0.92 cycles per access through the alias**, against 1.08 for an ordinary kernel address and **38 cycles** for the host's own bracketed user access. The alias is free; bracketing is not.

**What it costs.** A second translation-buffer entry per touched page, unmeasured. Two invalidations per address-space change, because the exported form of a kernel-range flush is missing. A hardening trade that has to be said plainly: a supervisor-readable window onto a tenant's pages is the confused deputy the hardware check exists to prevent, here defeated deliberately and in one place. And a cost nobody had priced, found by running it: the alias is a *translation*, not an access, so demand paging and copy-on-write do not happen through it, which is correct only while the kernelet owns every one of its tenant's pages.

**What it means for the host we wrote.** Four changes, all inside the framework, would let Asterinas enable the supervisor-access check for the first time, at a measured cost of about zero per access against 38 for the alternative. That is the most valuable thing in the exploration for the mode the book actually specifies.

**Verdict.** Promising, and the finding is worth more than the design.

## Per-instance module {#per-instance-module}

*Deliberately gives up **one physical image per kind**. Helps Linux only.*

The chapter rejects Linux's own module loader in one sentence. This design takes the rejection seriously enough to price it, by loading each instance as a genuine module and counting what comes free: the kernelet's exception table is searched, so a bracketed copy delivers the fallible contract; the text is made read-execute by the loader, so two mandatory exports disappear; the control-flow rewrite is applied by the loader, so the indirect-branch assumption is answered; probes may be placed in the text; unwind tables and symbols are registered, so backtraces resolve.

**Then it does the arithmetic, and the arithmetic is fatal.** A realistic image, measured on the tree, is 17.6 MiB per instance of address space and of memory. The region it must live in is 1008 MiB on a kernel with address randomization, which is what distributions ship, and the host's own modules take a bite first. That is **fifty-six sandboxes per machine**, against the thousands the density argument exists to claim.

**But the design earns its place by asking whether there is a middle**, and there is. One module per *kind* carries the rewritten, signed, unwind-bearing master; each instance is a mapping whose exception-table range is registered separately. Of the five benefits, the fallible contract survives — because an exception-table entry is **self-relative**, so one shared table read through instance N's mapping yields instance N's addresses, and only the *search* has to be taught. The rewrite survives for the same reason. Signing survives, and in fact the brief had it backwards: per-instance loading *breaks* signing, because instances need distinct names and renaming invalidates the signature. What does not survive is instrumentation, which is welded to per-instance text because a probe is a write into the instruction stream and the text is shared.

**Verdict.** The rejection was right, and its stated reasons were wrong in four particulars. The middle is what to build. And the design leaves behind one thing worth keeping whatever else happens: an instance loaded as a genuine module, from the same image, is a **debug mode** — one tenant under investigation, with probes and resolvable backtraces, at 17.6 MiB.

## Guest ring 0 {#guest-ring0}

*Deliberately gives up **kernel-mode execution**, the headline property. Helps Linux only, and would rewrite the book's opening claim.*

Each kernelet runs deprivileged, in the guest's own most-privileged mode, over an identity second-level translation of the same page tables it uses now. The first wave priced this in a paragraph and dismissed it. It deserved a design, because it is the only thing in the exploration that restores termination **outright**.

**What it restores.** The processor's own preemption timer bounds a kernelet's execution with no cooperation from it: the timer cannot be masked by disabling interrupts, and the kernelet cannot rewrite it, because the instructions that would are themselves exits. The test for whether a kernelet is killable becomes reading its instruction pointer out of the control structure, which is stronger than the per-task counter the host we wrote relies on.

It also **deletes** the entry-point problem rather than closing it, because the guest and host interrupt-descriptor tables are separate fields: a division error or a protection fault in the tenant never reaches Linux's handlers at all. Fourteen other items of the previous chapter go the same way. The tenant's address space is the kernelet's, so the ownership decision reverses and the tenant-memory decision, the boot setting and the stack decision are all withdrawn — the supervisor-access check can simply be left off for the guest and on for the host, which is a bit the host's own hypervisor already manipulates. The one ask that survives is the export pair.

**And service calls do not exit.** With an identity second-level translation, guest-physical is host-physical and the crossing is an ordinary function call, exactly as the design specifies. What exits is an interrupt, at about 0.8 percent of a core at ten thousand a second, and the timer bound, at 0.08 percent at a millisecond. So the exits are **preemption points**, not crossings — which is a thing the book has no word for.

**The costs, measured on the book's own build host.** An exit and resume with an in-kernel handler: **3,002 cycles, 792 nanoseconds**. Four different exit causes landed within three percent of each other, which is what shows the number is the round trip rather than the handler. And the cost nobody had priced, which the book's own summary figure denies exists: the second level of translation costs about 0.1 cycles per load while translations are resident and **1.20×** at a working set of 256 MiB, paid by every access of every tenant, forever.

**Extension or replacement: replacement.** It cannot be an extension of Linux's own hypervisor, for the reason the brief suspected. Tenant memory as host kernel addresses is not expressible there: memory slots are validated as user addresses, every guest frame is resolved by pinning against a user address space, and there is no identity second-level translation and no in-kernel way to run a virtual processor. Linux also takes an exclusive token on the virtualization feature at load. Coexistence is buyable with two small patches, but the endovisor becomes a hypervisor of its own.

**Verdict.** Promising, and a different book. The mechanism is real and the arithmetic works. But the Executive Summary's figure says "no hypervisor, no second-level translation, no exit", and this design makes all three false, while the crossing sentence in [Boundaries and trust](../design/principles.md) survives intact. Keep it as the honest answer to "what would all three properties actually cost?", and note that it is the only answer that gets all three.
