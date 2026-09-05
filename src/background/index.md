# Background and Motivation

This chapter gives the reader what the design assumes and where it came from; the case for giving every agent its own kernel is made in the [Preface](../executive-summary.md#industry). The Asterinas internals it leans on come first, in ten facts, each of which a later chapter relies on. Then the prototype this design grew out of: a software hypervisor with API virtualization that was built and booted, and the one-sentence synthesis that turned it into this design.

Two earlier design studies of the same problem shaped this one and are referred to by name in later chapters. **Alternative B** is the booted prototype described in this chapter. **Alternative A** was a design that rewrote the kernel's per-tenant state by hand into a per-instance struct, mediated devices through bespoke request types, and was modeled in user space but never booted; it was a research vehicle, and this book does not describe it further. Where a later chapter says it keeps something "from Alternative A", it means the discipline for memory accounting, threads, faults and reclamation that this design adopted from that study; where it prices a choice "against Alternative A", it compares with that study's cost.

In this chapter:

- [Asterinas in ten facts](asterinas.md)
- [An earlier prototype: a software hypervisor with API virtualization](prototype.md)
- [The synthesis in one sentence](synthesis.md)
