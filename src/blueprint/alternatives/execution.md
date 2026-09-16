# The execution environment

*Three designs against the cluster that contains the only outright soundness bug in Linux mode. A kernelet's per-processor data is selected by a virtual CPU number, and on Linux nothing makes that number stable or unique, so two of a tenant's threads can index the same replica at the same instant on different processors. The cluster also holds the kernel stack, fair accounting, and a limitation that turned out not to exist.*

## Derive the virtual CPU from the processor {#derive}

*Attacks:* the soundness bug. *Helps:* Linux only.

Stop assigning a virtual CPU to a task and make it a function of the processor the code is running on. Injectivity then holds by construction: two threads on different processors get different replicas because they are on different processors. The framework's preemption guard becomes the host's own pairing of a migration hold and a per-replica lock, which is the recipe Linux uses for its own per-processor data.

**What it costs.** Two atomic operations on every acquisition of a spin lock, which the kernel proper takes constantly. And one thing worth knowing before relying on it: on a kernel built without preemption, which is what the chapter's own experiments ran on, the host's preemption disable compiles to a compiler barrier and the migration hold is not available in the form the design wants.

**Verdict.** Promising, and the right fallback. The smallest change that makes the replica selector sound, if its cost measures acceptably.

## The seat {#seat}

*Attacks:* all four limitations of the cluster with one object. *Helps:* both hosts.

The design's question is whether the kernel proper cares *which* processor it is on. It does not. It cares that nobody else is touching its replica. So make the virtual CPU identifier name a **lease** rather than a processor.

A kernelet has as many seats as it has virtual CPUs. Entering kernelet code acquires one; leaving releases it. A seat carries the replica, the service-call depth the design already keeps, the accounting scope, and a processor-time accumulator that can refuse an acquisition when the instance is over its quota — which is a quota the host scheduler does not have to know about. Race freedom comes from possession rather than from pinning, so no build option of the host's is load-bearing, which is what makes this the only design in the cluster whose soundness survives an arbitrary kernel.

**What it costs.** An acquire and a release per crossing into kernelet code, and the honest answer to a question worth asking: the seat and the stack cannot be the same object. A seat must be released when the code sleeps, and a stack must not be.

**Verdict.** Promising, and the one to build. It is also the only design here that improves the host we wrote, because a lease is a better abstraction than a virtual CPU on either host.

## Be a process {#be-a-process}

*Attacks:* fair accounting. *Helps:* Linux only.

A kernelet's threads become threads of a per-sandbox carrier process, so that they inherit the sandbox's control groups. Accounting then becomes membership rather than bookkeeping: the memory a kernelet allocates and the processor time it burns are charged where they should be, by machinery that already exists, and the kernelet's work on a tenant's own task is charged to the same group.

That last part matters because it is the only correct answer available. Linux's processor-time accounting takes the group from the task, and nothing in the tree redirects it — not even its own virtual-machine monitor.

**Verdict.** Needs work, and worth it for the accounting alone. Fairness is one of the three properties the boundary owes, and this is the only design that gives it back.

## The limitation that was not one

The chapter records that a kernelet's pinned threads cannot join a processor set, so its budget must be a weight rather than a set of processors. That is wrong: the refusal applies only to a stricter form of the call that the ordinary affinity interface does not use, so creating a thread and then setting its processors yields one that is both pinned and attachable. Linux's own virtual-machine worker does exactly that. The row is withdrawn from the chapter, and no design was needed for it.
