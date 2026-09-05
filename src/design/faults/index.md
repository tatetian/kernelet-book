# Layer 7: faults, forced termination, and reclamation

This layer is Alternative A's, with the windows added. It is the layer Alternative B did not write, and the one a hypervisor engineer reads first.

From Alternative A: unwind and catch per thread; when unwinding cannot, abandon the stack at a **quiescent point**, a place where the thread holds no host lock and interrupts are enabled, so that discarding its frames leaves nothing shared inconsistent; destroy drains the host's references, unmaps the windows, forgets the arena root and releases every frame, poisoned.

This layer guarantees that panic, OOM, spin and kill each end one kernelet, and that reclamation needs no kernelet `Drop`. It is enforced by the quiescence predicate, the windows, and the drain list.

In this chapter:

- [Three tiers](tiers.md)
- [Out of memory](oom.md)
- [What the windows add](windows.md)
- [Destroy, step by step](destroy.md)
