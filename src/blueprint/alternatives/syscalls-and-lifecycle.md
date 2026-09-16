# System calls and the tenant's processes

*Three designs against the cluster the chapter calls its largest open item. All three start from the same correction: the chapter counted four system-call entry points and proposed hooking each, when every one of them funnels through a single generic function where the other three interception mechanisms already live. From there they diverge on a deeper question, which is what a tenant thread should be.*

## One gate, two primitives {#one-gate}

*Attacks:* all four items of the cluster. *Helps:* Linux only, and three other architectures with it.

**The gate.** Move the hook out of the architecture's entry code and into the generic entry layer as one more bit of work to do on the way in, placed after seccomp. Every entry reaches it: the 64-bit instruction, the legacy interrupt, both 32-bit paths, and the newer flavors. It inherits the existing convention for "an earlier stage answered this call" on both sides, so nothing downstream needs to change. The patch is *smaller* than the chapter's, it covers every entry by construction rather than by enumeration, and because the generic entry layer is shared, it covers other architectures too.

**The first primitive: the kernelet as a program loader.** A kernelet registers itself as a **binary-format handler**, which is a supported extension point Linux has exported since such handlers became loadable modules. When a tenant runs a program, the kernelet's handler builds the address space, attaches the task, and gives the task its user register state through the same call Linux's own program loader makes last. Three things fall out of this that the chapter treats as separate problems. The tenant's own `execve` is handled by the same path, so the lifecycle's hardest verb is answered by the mechanism that bootstraps the sandbox. The modern virtual system-call page is never mapped, because it is the program loader that maps it and this loader does not. And the loader's own reference counting holds a reference on the module for the life of the address space, which is one of the defects recorded against the chapter's patch.

**The second primitive: decline the call.** The hook does not have to service a call. `clone` is serviced by Linux, which returns twice correctly, and the kernelet does its bookkeeping on both sides. The child is attached before it exists, because the whole task structure is copied, and it leaves through the exit path rather than the entry path, so there is no window in which a child runs unattached. The chapter records that copying as a lifetime defect; it is the attachment mechanism.

One flag has to come with it. Linux copies a raw-frame-number area's page tables into a forked child, so without the flag that says *duplicate the area and copy no pages*, a tenant that forks shares its frames with its child, writably. That is a data leak in the design as specified, and it is fixed by setting one flag.

**Verdict.** Promising, and the one to build first. It is the smallest change that closes the entry-point escape and the lifecycle at once, and it needs no new exported symbol.

## Carriers: the host owns address spaces, not threads {#carriers}

*Attacks:* the assumption that a tenant thread must be a Linux task. *Helps:* Linux, and it makes the two hosts converge.

A tenant thread becomes a register frame, a floating-point buffer and a stack, owned by the kernelet — which is exactly what the framework's own task type already is. What the host owns is one address space per tenant and a small pool of **carriers**: Linux tasks whose address space is the tenant's, one per virtual CPU, pinned.

A carrier returns to user mode carrying one tenant thread, comes back on that thread's next system call, and can then pick up a different one. The crossing inverts back to the design's own shape: `user_run` becomes a call that really enters user mode and returns with a reason, rather than a shape the framework imitates for a kernel proper that must not know the difference.

The consequences reach further than the cluster. The framework's own scheduler, which Linux mode leaves inert, goes live again. The per-CPU replica selector becomes injective by construction, because there are exactly as many carriers as virtual CPUs. And the set of tasks that cannot be killed shrinks from every tenant thread to one per virtual CPU.

**What it costs.** A register-frame copy per crossing, which is what returning from a signal already costs. And four places where it can die: the floating-point state, whose exported swap helper is present only on a kernel built with virtualization support; Linux's validation on the way out of a register frame it did not write; a signal or a forced trap arriving on a carrier that is *between* tenant threads; and the concentration of a tenant's concurrency onto a few carriers. That last one was expected to make the model page table's lock contention worse and, when it was built, turned out to make it better: the number of page-table cursors held at once falls from every tenant task the host is running to the number of virtual CPUs. The [whole-mode page](whole-mode.md#carriers) has the measurements.

**Verdict.** Needs work, and worth the work. It has the highest ceiling of anything in the exploration, because it is the only design that makes Linux mode and Asterinas mode the same design rather than two implementations of one interface.

**One idea from a design that did not survive.** A third approach anchored the kernelet on the **address space** rather than on the task, so that threads share a kernelet for free and the lifetime rules become the ones Linux already runs. It was overtaken: most of the defects it repaired were repaired by the corrections this exploration made along the way. What is worth keeping is its framing, which is that losing your kernelet should mean losing your memory rather than escaping your kernelet.
