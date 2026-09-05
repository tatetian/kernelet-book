# The bill, against Alternative A

| item | Alternative A | this design |
|---|---|---|
| per-tenant statics | 96 declarations rewritten into `KerneletState`; ~722 functions gain a parameter; 115–1,128 types gain a back-pointer; the VFS bucket unmeasured | **zero source change**; a linker-script section and a `memcpy` at create |
| `ostd::` paths | ~214 of 685 rewritten | **zero**; one manifest line, six facade-defined macros, and about a dozen sites that used absent items ([§4.2.3](../design/facade/item-kinds.md)) |
| drivers and device kinds | ten bespoke kinds; drivers into the host; `aster-block` completion rewritten; page-cache frame state moved out of `MetaSlot`, OSTD's per-frame metadata slot (still needed here) | six kinds; virtio front-ends stay; host gains virtio backends (a specification exists) |
| inter-kernelet communication | copying pipe, credit | `RRef` ownership transfer, vsock semantics, credit; the transfer path measured on the booted prototype ([§2.2](../background/prototype.md)) |
| Host pointer into a kernelet (the [rule-2](../design/memory/arena.md) bug class) | type bound + poison | type bound + poison + **page fault** |
| task switch | CR3 write as today | a CR3 write on *every* switch between tasks of different page tables, host and idle tasks included; every such write also drops both windows' translations, on same-kernelet switches too; PCIDs ([change 18](../architecture/tcb.md)) would keep the write and remove the flush **[unverified]** |
| service call | vtable + scope switch + ~16-cycle resolve | the same, plus a stack check (39 cycles on the booted prototype) |
| per-kernelet memory floor | one grain + magazines + stacks | the same plus the data window (a few pages) |
| OSTD changes | fifteen | nineteen: thirteen of Alternative A's (its `MetaSlot` owner tag and its interrupt-prologue change are not needed), plus the window page table and linker sections, the window-addressed slab, the double-fault handler, the switch policy, and PCIDs as an option |
| what still moves | ~13,000 lines of host subsystems; thread state into the task; `Arc<Task>` → names; the `xarray` rewrite; `#[kernelet_drop]`; the soft-band checks and `try_reserve` wrappers | the same, minus nothing |

The rows that changed are the ones Alternative A's own cost table called unmeasured and largest. What has not changed is the second half of that table: the thread-state relocation (about 90 sites), the naming of tasks (34 sites), the `xarray` rewrite, the page-cache frame state out of `MetaSlot`, the soft-band sweep, and the OSTD list. Those are the real cost of kernelets and no framing removes them.
