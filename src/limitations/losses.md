# Where this design loses

**1. Nothing of this design has booted.** Alternative B booted one guest without the multi-instance mechanism; Alternative A booted nothing. Every claim about the windows, the facade's manifest trick, the backends and the drain list is a design.

**2. The windows are a page-table mechanism in a design that promised not to need one.** They cost a non-Global mapping, a differing top-level entry, a CR3 write on every switch between page tables, and the windows' translations on each; they demand that the linker script and the audit agree on which crates are the kernelet closure; and the booted prototype's numbers were taken without the CR3 writes and window flushes they add; and they give a *partial* hardware backstop, host-versus-kernelet and kernelet-versus-kernelet, never "host acting for A" versus "host acting for B". A reader who wanted a pure language boundary should say so here.

**3. The TCB is large, and the mediating mechanisms are a rounding error inside it.** About 100,000 first-party lines plus the language runtime after two levers; the drivers, which parse device input, are the least-reviewed part. The virtio backends are new attacker-facing code; their saving grace is that a specification and a fuzzing literature exist for them.

**4. The kernelet crate is 110,000 lines of mutually trusting code.** A confused-deputy bug inside a kernelet's own kernel is caught by nothing here; it hurts only that tenant, but a microVM's guest kernel sits behind a second hardware boundary and this design's second boundary is two mappings.

**5. Host lock hold times are an assumption, and kernel preemption is not in the tree.** A kernel stack overflow while a host lock is held, inside the cursor, or in interrupt context is still a machine halt: the double-fault handler can only abandon a stack at a quiescent point. A kernelet cannot hold a lock another kernelet needs; every remaining stall goes through host code, whose bounded hold time is a review obligation. Until OSTD preempts in kernel mode, the 100 ms budget is the only thing that ends a preempt-enabled kernel-mode loop.

**6. The reclamation theorem has an enumeration and a proof obligation inside it.** The drain list must be complete; the frame-reset obligation is outside `vostd`; and the windows turn a missed reference into a fault, not into nothing.

**7. Soft-band holes are ABI bugs waiting to be found**, and a missed size cap or an unreserved cursor operation is a machine kill: pipe buffers, socket backlogs, `epoll` sets, `inotify` watches and dentry growth are the classic misses.

**8. The page cache must learn to shrink.** The tree has no reclaim; per kernelet, a workload that reads more file data than its grant fills its cache and then takes `ENOMEM` elsewhere. A per-kernelet shrinker is new code, and the overlay filesystem's copy-up allocates one contiguous segment per file today.

**9. The memory floor is worse than a container's**, the dedup story is absent (two kernelets reading one image hold two copies), and the magazine bill scales with affinity, which is a scheduling restriction.

**10. Cross-kernelet `SCM_RIGHTS` is gone**, and "zero copy" is kernel-to-kernel: the user copies stay until frame gifting is built.

**11. Every enumeration of safe items in the two alternatives was found incomplete by the next review**: the facade's library rows, the destroy ordering, the active address space, the cursor's lock, and, in Alternative B, the multi-instance data conflict. The base rate is the finding, and this book's lists should be attacked the same way.

**12. Everything rests on `rustc`, `core`, `alloc`, the unwinder and OSTD's `unsafe` being sound.** A miscompilation collapses the isolation property at once; the windows catch some consequences and not others. A hypervisor faced with the same bug still has nested page tables.
