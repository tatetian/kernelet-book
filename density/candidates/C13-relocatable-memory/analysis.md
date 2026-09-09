# C13: Relocatable kernelet memory (kernelet-physical addresses)

**Status:** adopted as the enabler of C03, C05 and C07. **Depends on kernelets:** yes, in mechanism: it gives a kernelet what the EPT gives a VM, a second naming of memory that the host may rebind, without a second-level page walk or a VM exit. **Acts on:** nothing by itself; it is what makes host-driven eviction, cloning and compression *sound*.

## The problem the reviews found

The Blueprint's Memory page (register D58) names every frame a kernelet holds by its **machine physical address**: the window maps `KW_PHYS + paddr`, vOSTD's `Frame` carries that `paddr`, and the kernelet writes it into the leaf entries of its own user page tables, which the CPU walks natively. That is the simplest possible design, and it is why `paddr_to_vaddr` and the frame code are the tree's own. It also means a kernelet's memory is **not relocatable**: the host cannot evict a grain and bring it back in a different frame, because the tenant's page tables, the kernelet's `Frame` objects, its allocator's free lists and its device descriptors all still hold the old address, and a tenant process would then read and write whatever the old frame now holds, another tenant's memory, through ring-3 accesses that never fault. The reviews of C03 and C05 found exactly this: host-transparent paging as first drafted was an isolation break, and a copy-on-write clone would map the template's frames. Nor can a kernelet be hibernated to disk and restored elsewhere, which is the 5 s tier's whole mechanism.

## The mechanism

Give each kernelet its own **kernelet-physical address space**, dense, starting at 0, sized by `max_grains`; call its addresses `kpaddr`. This is what a guest-physical space is to a VM, and what Xen's paravirtualized guests had with their physical-to-machine and machine-to-physical tables.

- The window is indexed by `kpaddr`: `KW_PHYS + kpaddr` maps whatever machine frame the host currently backs that kernelet-physical page with, and `KW_META + kpaddr / 64` holds its metadata. Both stay host-written and sparse; a grant is a run of kernelet-physical grains bound to machine grains.
- The **p2m table**, one `u64` per kernelet-physical grain, host-written, read-only to the kernelet, in `KW_SHARED`, gives the machine address of each grain; the reverse map, machine grain to (kernelet, `kpaddr`), is the owner array extended by a `kpaddr` field.
- vOSTD's `Frame`, `Segment`, `paddr_to_vaddr`, the allocator and the metadata all work in `kpaddr` and stay the tree's code: `Paddr` in vOSTD *is* `kpaddr`. Two places must produce or consume machine addresses, and both are inside vOSTD's page-table code, which is trusted: a leaf entry written into a user page table carries `p2m(kpaddr)`, and a leaf entry read back (`query`) is translated by the reverse map. Intermediate page-table nodes are addressed by `kpaddr` through the window when the kernelet walks them, but the entries that point at them must hold machine addresses for the CPU, so the same translation applies to node pointers: one lookup per entry written, none per access.
- Device descriptors carry `kpaddr`; the endovisor's `guest_memory(kpaddr, len)` translates through the kernelet's p2m under the same pin as today. The host's own accesses to kernelet memory (the service half's fallible copies, the borrowed image grains of C01) are unchanged: they go through the window or the linear map with a machine address the host looked up itself.
- The host may now **rebind** a kernelet-physical grain: evict it (C03, C07), copy it (C05), or restore it (hibernation). The one thing a rebinding must also do is fix the entries that hold the *old* machine address: the leaf and node entries of the kernelet's registered page tables. Two ways, and the design takes the second: (a) the host walks the kernelet's registered roots and rewrites entries that point into the grain, which is bounded by the kernelet's page-table size (a 60 MiB working set is on the order of a hundred page-table pages, a few hundred microseconds to scan); (b) the **kernelet clears its own entries first**, cooperatively, when asked (`JOB_SHRINK` of C02 carries the grain list), since it has the reverse mappings the kernel proper keeps for every mapped frame, and re-establishes them on the next fault through the tree's own minor-fault path, at which point the leaf write translates through the p2m and lands on the new frame. (b) keeps the host out of tenant page tables and costs the kernelet a fault per re-touched page after a restore, which is the same fault storm a VM pays through the EPT.

## What it costs

- A translation on every leaf or node entry written by the page-table cursor and on every entry read by `query`: one indexed load into the p2m or the owner array. The tree's `map` already does more work than that per entry; *estimated* at 2–5 ns per entry, against the EPT's second-level walk on every TLB miss for a VM, which is the cost this design replaces.
- The p2m table: 8 bytes per grain, 4 KiB per GiB of kernelet-physical space.
- The `page_table` module of vOSTD becomes a virtualized item on the taxonomy page (it is internal to OSTD, so no kernel-proper change); `query` and the cursor's leaf writes get a second body under the feature. `HasPaddr` on `Frame` returns `kpaddr`, which is what every caller in the kernel proper expects a physical address to be for its own purposes.
- It reopens part of the choice register D58 made: the window is dense in `kpaddr` rather than sparse in machine addresses, which is closer to the design D58 replaced (register D13's slots), but it keeps D58's property that the kernelet writes no window page-table entry and that the metadata is a sparse host-mapped window. The identical-code list loses `page_table::*` and keeps everything else.

## What it enables

- **C03** becomes sound: the host may evict a cold grain to NVMe or the compressed pool once the kernelet has cleared its entries, and restore it into any free frame.
- **C05** becomes definable: a clone gets a fresh p2m over copy-on-write bindings to the template's machine grains; its page-table frames are copied and their entries translated at clone time (bounded, sub-millisecond for a template with a hundred page-table pages), or start empty and refault.
- **Hibernation** at the 5 s tier becomes a real mechanism: a kernelet's private grains written out with their `kpaddr`, restored into whatever frames are free.
- **Memory migration between NUMA nodes or to far memory (C08)** becomes possible later for the same reason.

## Isolation

Strengthened rather than weakened: a kernelet never learns a machine address, so a stray value in its page tables cannot name another tenant's frame by accident, and the two translation points sit in trusted vOSTD code that already owns every page-table write. The p2m is host-written; a kernelet that corrupted its own leaf entries could only ever name machine frames the p2m binds to it, because vOSTD is the only writer and it translates through the p2m. (That last property holds against a *bug* in the kernel proper; against a compromise of vOSTD nothing holds, as everywhere in the design.)

## Evidence

- Analytic: the reviews' counter-examples (a tenant PTE naming a reused frame; a clone mapping the template's frames) are exactly the cases a p2m removes.
- Published: Xen paravirtualization ran production guests on p2m/m2p tables for two decades; the EPT's per-miss cost that this avoids is the cost the Paper's page-fault measurement (10,345 cycles in the prototype against 9,791 native) already reflects on the kernelet side.

## Changes to the Blueprint

Recorded here, not applied: `Paddr` inside vOSTD becomes the kernelet-physical address; the p2m table in `KW_SHARED` and a `kpaddr` field in the owner array; `page_table::*` virtualized at leaf and node entry writes and at `query`; `guest_memory` and `pt_root_register` take `kpaddr`; register D58 revised to "window indexed by kernelet-physical address, mapped by the host"; the Memory page's `RunDesc` gains the run's `kpaddr` base.
