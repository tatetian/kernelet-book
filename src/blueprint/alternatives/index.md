# Alternative designs for Linux as the host (WIP)

*[Linux as the host](../linux-mode/index.md) ends with a list of things it cannot do. This chapter attacks that list. Every design here was produced by treating one limitation as a problem to be solved rather than a cost to be recorded, and every design states what it gives up, because a design that gives up nothing has usually not understood the problem. The chapter closes by comparing them and choosing.*

## Why a chapter of alternatives

A design document that ends in a list of admitted failures has done half its job. The other half is to ask whether each failure is a property of the problem or an artifact of the first answer that was tried.

The previous chapter's list is long: a runaway kernelet cannot be stopped, a fault in kernelet code is a Linux oops, kernelet code may not dereference a tenant's address, the per-CPU model is unsound, the kernel stack is a thirty-second of what the design assumes, three of four system-call entry points are unhooked, the tenant's process lifecycle is not designed, and a class of kernel may refuse to run a kernelet at all. Against that, the chapter's conclusion is narrow: nothing found rules out a patched Linux built without type-checked indirect branches.

This chapter assumes the opposite posture. In systems work every design is a trade, and a design that loses on one axis may be bought back on another for less than it appears to cost. So each limitation here is attacked rather than recorded, with one rule: anything below the kernel proper may change, including the framework's own interface, if the argument is strong enough. The Asterinas kernel above that interface still may not, because that is the claim the whole design rests on.

## What the exploration found first

The first result was not a design. It was that the chapter being attacked is wrong, in twenty-one specific places that are [enumerated with their citations](../../notes/alternatives-corrections.md) in The Notes, and that several of its limitations are smaller than it claims or already answered by interfaces Linux has had for thirty years.

Two examples set the tone. The chapter requires the operator to boot with the legacy virtual system-call page disabled, because that page reaches three system calls below every interception point. It does not: it calls seccomp first, and seccomp's filter input carries the instruction pointer, so a short filter closes it per sandbox with no patch and no boot setting. And the chapter calls the tenant's process lifecycle its largest open item, on the grounds that only Linux can give a task a user context. Linux has exported the machinery for out-of-tree code to do exactly that since binary-format handlers became loadable modules.

Both corrections are already folded into the previous chapter. They are mentioned here because they say something about method: the chapter asked what a module is allowed to do, and the better question was what extension points Linux already has for code that wants to own a process.

## How the designs were produced

Two waves. In the first, one agent per cluster of limitations, each asked for several distinct fixes and for an honest verdict on each. A coordinator then ranked what came back, found the pairs that cannot both be adopted, and specified the second wave. In the second, whole-mode designs: coherent answers to every limitation at once, with their trades made deliberately, including designs that deliberately give up one of the book's headline properties to buy the rest.

Every design carries the same three labels, so that they can be compared rather than admired: what it attacks, which hosts it helps, and a verdict, with its mechanism, its cost and its failure modes in between. Designs that failed are here too, with the reason, because the reason is what stops the next reader retrying them.

The bar was **restoration, not mitigation**: a design counted as a success only if it brought a property back to where the host we wrote holds it. The [comparison](comparison.md) says plainly which designs met it.

The transcripts of the three designs that were built and run, and a table of every symbol and fact the rest turn on with its file and line, are in [Alternative designs: what was measured](../../notes/alternative-designs.md) in The Notes.

## In this chapter

Five pages of first-wave designs, one per cluster of limitations, then the whole modes, then the comparison.

- [Containment: stopping a kernelet, and surviving its faults](containment.md) — the two limitations that cost the boundary most, and the correction that a kernel-mode fault need not be fatal.
- [Tenant memory: deleting the map instead of keeping it](tenant-memory.md) — three answers to the chapter's newest decision, including one that would improve the host we wrote.
- [System calls and the tenant's processes](syscalls-and-lifecycle.md) — one gate instead of four hooks, the kernelet as a program loader, and what a tenant thread ought to be.
- [The execution environment](execution.md) — the per-processor soundness bug, the kernel stack, accounting, and a limitation that turned out not to exist.
- [Loading, and the hardware underneath](loading.md) — the density cap, the assumption that could exclude a class of host, and writing page-table entries directly.
- [Whole modes](whole-mode.md) — coherent alternatives that answer every limitation at once, including two that give up something the book treats as settled.
- [The comparison, and the choice](comparison.md) — the designs side by side, what to build, and what the exploration did not achieve.
