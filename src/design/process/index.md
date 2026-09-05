# Layer 1: the process, or where a kernelet's bytes live

Two windows per kernelet in the kernel half, one for the kernelet crate's `.data` and `.bss` and one for its heap arena, at the same virtual addresses in every kernelet, each backed by that kernelet's own frames, reachable only through that kernelet's page tables. The host's own tasks, in thread context, map neither window. The per-tenant `static`s of the kernel become per-kernelet with zero source change, and the two windows are a hardware backstop whose price is a CR3 write on switches the tree does not pay for today and, without PCIDs, the windows' TLB entries on every switch.

This layer guarantees that every `static` of the kernel is per-kernelet, and that a pointer into a kernelet's memory dereferenced by a host task in thread context faults. It is enforced by the linker script and a link-time audit that no kernelet-crate writable object lies outside the window and no host object inside it.

In this chapter:

- [The problem the windows solve](problem.md)
- [Two windows](two-windows.md)
- [The switch policy: every task activates its own page table](switch-policy.md)
- [Putting the kernelet crate's sections in the data window](data-window.md)
- [Putting the arena in the heap window](heap-window.md)
- [What the process gives the rest of the design](consequences.md)
