# Memory

*Part of question 2. Virtualizes `mm`: frames and their metadata, the heap, `paddr_to_vaddr`, address spaces and page tables, TLB shootdown, and the DMA objects. Discharges invariants I2 (ownership) and I3 (privacy) on the kernelet side.*

A kernelet's memory is a set of **runs**: physically contiguous, 2 MiB-aligned sequences of **grains** the host has granted it, and nothing else. Everything the kernel proper allocates, every frame of every process, every page-table node, every slab, every DMA buffer, comes from a run; OSTD (kernelet build) addresses its frames only through the **heap window**, `KW_HEAP`, where every grain is mapped at a fixed offset given by its **slot**; and the metadata OSTD keeps per frame lives inside the run the frame belongs to. The host's own frame metadata is never shared with a kernelet, which is what makes reclamation a release of whole runs with no per-frame obligation. The kernelet never writes a page-table entry that lives in host memory: the host installs the window's level-2 tables, in frames of the kernelet's own grant, and maps the initial grant itself; the kernelet maps later grains by writing entries into those same frames.

## Runs, grains, slots, and the grant table

A run of `n` grains occupies `n` consecutive slots, so it is contiguous in the window as it is in physical memory. The grant table records every run and is **written by the host, read by the kernelet**: it lives in `KW_SHARED`, appended by `create`, `grant` and `grains_request`, with its length published in the info page. Beside it the host keeps, also in `KW_SHARED`, a per-kernelet radix from physical grain number to slot, so that the kernelet can turn any physical address of its own into a slot with two loads and no bookkeeping of its own.

```rust
// ostd::kernelet::abi, host-written, kernelet-read. In `KW_SHARED`.
#[repr(C)] pub struct RunDesc {
    pub paddr: u64,        // 2 MiB-aligned physical base of the run
    pub first_slot: u32,   // slot of its first grain; the run occupies first_slot .. first_slot + grains
    pub grains: u32,
    /// Frames at the head of the run reserved by the host for the window's level-2
    /// tables that this run brought with it; `0` for most runs.
    pub l2_frames: u32,
    pub _pad: u32,
}
// `InfoPage::runs` is the published length of the `RunDesc` array at `BootArgs::grant_table`.
// `BootArgs::grain_radix` is a two-level table: 4096 top entries of 512 MiB each, sized to
// the machine's physical memory, each pointing at a 256-entry leaf of `u32` slots (`NONE` if
// not the kernelet's); leaves are host frames mapped as they are needed.

// OSTD (kernelet build)
pub const KW_HEAP: Vaddr = KERNELET_WINDOW + (4 << 30);
pub const GRAIN_SIZE: usize = 2 << 20;
pub const MAX_SLOTS: usize = 65_536;            // 128 GiB per kernelet in this version; `KW_HEAP` is 508 GiB

/// The slot of one of the kernelet's own physical addresses: two loads in the shared radix.
pub(crate) fn slot_of(pa: Paddr) -> Option<u32>;

/// Virtualized `paddr_to_vaddr` and its inverse. A frame outside the grant is a bug in
/// OSTD (kernelet build), not a condition the kernel proper can cause, and panics.
pub fn paddr_to_vaddr(pa: Paddr) -> Vaddr { KW_HEAP + slot_of(pa).unwrap() as usize * GRAIN_SIZE + (pa & (GRAIN_SIZE - 1)) }
pub(crate) fn vaddr_to_paddr(va: Vaddr) -> Paddr { let slot = (va - KW_HEAP) / GRAIN_SIZE; run_of_slot(slot).paddr + (slot - run.first_slot) * GRAIN_SIZE + (va & (GRAIN_SIZE - 1)) }
```

The radix is sized by the host from physical memory, so a kernelet can hold a grain anywhere in the machine; the cap on slots, 65,536, is this version's limit on a kernelet's memory and is checked against `max_grains` at `create`.

## How memory arrives

**At creation**, the host does the whole bootstrap, so that the kernelet's first instruction runs with memory it can use:

1. Allocates the initial grant as runs, with `alloc_segment_aligned` ([control half](../kernelet-api-control.md)), records them in the grant table and the owner array.
2. Reserves, at the head of the first run, enough frames for the window's level-2 tables covering `max_grains` slots (one table per 512 slots; four frames for a 4 GiB maximum), records the count in `RunDesc::l2_frames`, zeroes them through the linear map, and writes the corresponding level-3 entries into the window's level-3 table, which is a host frame.
3. Writes, into those level-2 tables, one 2 MiB page entry per initial grain, read-write, non-executable, not Global.
4. Fills the radix.

**After creation**, `grant` (from the endovisor) and `grains_request` (from the kernelet) append runs the same way, except that the kernelet maps them: it reads the new `RunDesc` entries past the length it last saw, and writes each grain's level-2 entry into the level-2 tables the host installed, which are frames of its own first run, reachable through the window. If a run raises `max_grains` past the installed coverage, the host reserves level-2 frames at that run's head, installs them, and writes the level-3 entries before publishing the run; the kernelet never writes a level-3 entry. A `JOB_GRANT` job tells the kernelet's worker to look at the table again.

For every run, in either case, OSTD (kernelet build) then lays out the run's metadata (below), and hands the run's usable frames to the kernel proper's frame allocator with the identical `GlobalFrameAllocator::add_free_memory` hook, one call per run. From then on the kernel's own allocator, the buddy allocator of `osdk/deps/frame-allocator`, manages the frames with its code unchanged; its per-CPU pools and caches use `cpu_local!` and `LocalIrqDisabled` locks, which are virtualized per virtual CPU and to preemption guards ([Tasks](tasks.md), [Interrupts and time](interrupts-and-time.md)), so its correctness now rests on the host honoring the preemption count across the allocator's slow path, which the host does.

Everything the kernelet writes here is in its own grant: the level-2 entries live in reserved frames of its runs, the metadata in its runs' frames, the allocator's free lists in its metadata. Everything the host writes is host memory or, at creation only, the kernelet's reserved frames through the linear map. That is invariant I2 as this page discharges it, and it needs no exception for page-table nodes: a user page-table node is a frame from the grant, mapped in the window, and OSTD's page-table code reaches it through the virtualized `paddr_to_vaddr` (checked on the tree: `ostd/src/mm/page_table/node`, `cursor/locking.rs` call `mm::paddr_to_vaddr`), which is the window.

## Frame metadata inside the run

OSTD keeps one 64-byte `MetaSlot` per physical frame (`META_SLOT_SIZE`, checked on the tree, `ostd/src/mm/frame/meta.rs`) in a global array indexed by frame number, through the `mapping` module's `frame_to_meta` and `meta_to_frame`, bounded by `max_paddr`. The kernelet build keeps the same slots for its own frames, but at the head of each run, after the level-2 frames if any: a run of `n` grains reserves `8n` frames for the metadata of its `512n` frames, 32 KiB per grain, and OSTD (kernelet build) replaces the `mapping` module, not just `get_slot`:

```rust
// OSTD (kernelet build), ostd/src/mm/frame/meta/mapping.rs under the feature
pub(crate) fn frame_to_meta(pa: Paddr) -> Vaddr {
    let run = run_of_slot(slot_of(pa).unwrap());
    let meta_base = KW_HEAP + run.first_slot as usize * GRAIN_SIZE + run.l2_frames as usize * PAGE_SIZE;
    meta_base + ((pa - run.paddr) / PAGE_SIZE) * META_SLOT_SIZE
}
pub(crate) fn meta_to_frame(va: Vaddr) -> Paddr {
    let run = run_of_slot((va - KW_HEAP) / GRAIN_SIZE);
    let meta_base = /* as above */;
    run.paddr + ((va - meta_base) / META_SLOT_SIZE) * PAGE_SIZE
}
pub(crate) fn max_paddr() -> Paddr { /* the highest granted address; `is_initialized` as on the tree */ }
```

`get_slot` keeps its alignment check and its bounds check, the latter now "is in the grant". The reserved frames, level-2 and metadata alike, are never handed to the frame allocator, and their own slots are marked reserved when the run is laid out, so nothing can allocate or reset them. `Frame`, `UniqueFrame`, `Segment`, `FrameRef` and `LinkedList`, and the callers that reach `frame_to_meta` directly (`from_raw`, `inc_frame_ref_count`, the list nodes; checked on the tree) are the identical code over these slots.

The cost is 32 KiB per grain, 1.56 percent of the grant, plus the level-2 frames of the runs that carry them; a run of `n` grains has `512n − 8n − l2_frames` usable frames, and since the reserved frames are at the run's head, the rest is one contiguous range for the buddy allocator. What it buys: the host's metadata array is untouched by kernelets, the kernelet's metadata dies with the run, and destroy has nothing per frame to reset.

## Allocation, contiguity, and exhaustion

`FrameAllocOptions::alloc_frame` and `alloc_segment` are identical: they call the kernel proper's global frame allocator, which is the kernelet's own buddy allocator over its runs, and initialize the frame's slot with `Frame::from_unused`, identical over the virtualized mapping. The zeroing write goes through the virtualized `paddr_to_vaddr`.

When the allocator returns `None`, OSTD (kernelet build) asks the host before giving up:

```rust
// OSTD (kernelet build), the body behind the identical `FrameAllocOptions::alloc_*`
fn alloc_with_refill(layout: Layout) -> Option<Paddr> {
    if let Some(pa) = global_frame_allocator().alloc(layout) { return Some(pa); }
    let grains = grains_for(layout);                                   // enough contiguous grains for `layout`, or REFILL_GRAINS (4, chosen)
    if services().grains_request(grains, /* contiguous */ 1) > 0 {
        map_new_runs();                                                 // read the grant table past the last seen length; map; lay out; add_free_memory
        return global_frame_allocator().alloc(layout);
    }
    None
}
```

`grains_request(count, contiguous)` asks for `count` grains as one run when `contiguous` is set; the host grants at once from its free memory up to `max_grains`, and at that limit consults the endovisor if the policy allows ([control half](../kernelet-api-control.md)). **Contiguity is what a run gives and no more**: the largest physically contiguous allocation a kernelet can make is the largest run the host can find for it, which fragmentation of the host's allocator bounds. The kernel proper does make large contiguous requests, a copy-up in the overlay file system and the block-group descriptors of `ext2` among them (checked on the tree: `kernel/core/src/fs`), so this is a tenant-visible limit: such a request fails with `ENOMEM` when the host cannot supply a run, as it would on a fragmented machine, and a heap object over the largest run the kernelet holds ends the kernelet through the allocation-error path below. The refill size `REFILL_GRAINS` trades the frequency of requests against the fragmentation each large run costs the host.

A refused request becomes `Error::NoMemory` from `FrameAllocOptions`, the error the host kernel sees when its own allocator is empty, and the kernel proper's own handling applies: `ENOMEM` to the process that asked, or the kernelet's OOM killer. The host never kills a kernelet for memory. A kernelet whose kernel cannot absorb the failure, because an infallible path, a slab refill for a `Box`, met it, reaches `#[alloc_error_handler]`, which in the kernelet build calls the `panic` service with "out of memory"; that ends the kernelet as `Panicked`, and only the kernelet ([Faults, termination, and reclamation](../faults-and-reclamation.md)).

`dealloc` is identical: frames return to the kernelet's buddy allocator and never to the host. Memory only grows (register A1) and is returned in whole runs when the kernelet is destroyed. The buddy allocator's per-virtual-CPU pools can hold frames a request on another virtual CPU cannot see (the tree's own comment in `pools/alloc` admits it), so a small kernelet with many virtual CPUs may report `NoMemory` with free frames in a neighbor's pool; the floor estimate below counts it.

## The heap

The kernel proper's slab allocator, `osdk/deps/heap-allocator`, is bound through the identical `GlobalHeapAllocator` hook, and the `core::alloc` global allocator of the kernelet image is OSTD (kernelet build)'s, which calls that hook. Three internals are virtualized without a crossing: `HeapSlot::paddr` and `HeapSlot::as_ptr`, which on the tree translate through the linear map (`ostd/src/mm/heap/slot.rs`), translate through the heap window; `HeapSlot::alloc_large`, which forgets a `Segment` and takes its address, takes the window address; and `DynCpuLocalChunk` with `DynamicCpuLocal`, which the heap allocator's per-CPU allocator uses (checked on the tree: `osdk/deps/heap-allocator/src/cpu_local_allocator.rs`), is virtualized so that a chunk is a grant `Segment` addressed through the window and `get_on_cpu` indexes by virtual CPU. The slab's per-CPU caches use `cpu_local!`, virtualized per virtual CPU ([Tasks](tasks.md)). Every heap object in a kernelet therefore lives at a `KW_HEAP` address, and a `Box` in a kernelet holds a pointer that resolves only on that kernelet's page tables, which is invariant I3's guarantee against a stray host pointer.

## Address spaces and page tables

`VmSpace::new` is virtualized without a crossing: it allocates a root frame from the grant and copies the 256 kernel-half entries from `BootArgs::kernel_half_entries`, which the host filled from the kernelet's kernel page table; entry 500 among them is the kernelet's own window level-3 table, so every address space the kernelet creates sees its window. On the tree the copy is made from the host's `KERNEL_PAGE_TABLE` (checked: `ostd/src/mm/page_table/mod.rs`, `create_user_page_table`); in the kernelet build the source is the array, and the code is otherwise the same.

`VmSpace::activate` is virtualized: on a space's first activation OSTD (kernelet build) calls `pt_root_register(root)`, and on every activation `pt_activate(root)`, which writes CR3 and records the root as the task's address space so that the host's scheduler restores it on every switch to the task. The tree's early return, which skips the CR3 write when the space is already active, is keyed by CPU on the tree (`ACTIVATED_VM_SPACE`, a per-CPU cell; checked) and **by task** in the kernelet build, since CR3 is restored per task: the kernelet-side task table records each task's last-activated root, and `activate` compares against that, so two tasks on one virtual CPU that activate the same space each call `pt_activate` once. Dropping a `VmSpace` first calls `pt_root_unregister(root)`; if the host refuses with `-STATE` because a task still records the root, the `PageTable` is moved to a kernelet-side pending list and the drop is retried at every successful `pt_activate` and at every task exit. A task's exit path, in `run_task` before `task_exit`, calls `pt_activate(kernel_pt_root)`, the kernelet's own kernel page table, which the host accepts as the "no user space" root, so that an exiting thread's process page table becomes unregisterable and is freed by the next retry; without that, every exited process would leak its page table.

The cursors, `map`, `unmap`, `protect_next`, `query` and `find_next`, are the identical page-table walk: node frames from the grant, addressed through the window, leaf entries for `UFrame`s from the grant. Their `PageProperty`, `PageFlags` and `CachePolicy` are identical. `map_iomem` and `find_iomem_by_paddr` are unreachable in a kernelet: their only producer is the framebuffer device, a host-only component (checked on the tree: `kernel/core/src/device/fb.rs`), so the kernelet build makes the first a no-op and the second return `None`; a virtual device has a register file, not memory ([Devices](devices.md)).

**TLB shootdown.** A local invalidation is the identical `invlpg`, a privileged instruction a kernelet may execute since it runs in ring 0. A remote one cannot be an inter-processor interrupt, since `smp` is absent, so `TlbFlusher::dispatch_tlb_flush` is virtualized: for each operation in its batch (the tree batches up to 32 page or range operations and collapses beyond that to a flush of everything non-Global; checked on the tree, `ostd/src/mm/tlb.rs`) it calls `tlb_shootdown(root, start, len)`, with `len == u64::MAX` meaning everything non-Global under that root, the user half and the window; the host, which knows on which CPUs the root has been active since `pt_activate` recorded them, sends the interrupts and waits before returning. Because the call is synchronous at dispatch, the frames the flusher keeps alive until the flush completes can be released at dispatch, which preserves the tree's `sync_tlb_flush` guarantee. Mapping a new grain needs no shootdown: it turns an absent entry present, and x86 does not cache absent translations; nothing in this design unmaps or downgrades a window mapping while a kernelet lives (register A1).

## DMA objects

`DmaStream`, `DmaCoherent` and their direction types are virtualized without a crossing: the frames come from the grant, `daddr()` returns the physical address, `sync_to_device` and `sync_from_device` do nothing, and the `is_cache_coherent` argument is ignored, since the "device" is a device model in the host that reads and writes the kernelet's frames through `Kernelet::guest_memory`, coherently, after checking that every frame of a descriptor is the kernelet's ([Devices](devices.md)). On the tree the non-coherent paths map through `KVirtArea` and `prepare_dma` consults the IOMMU (checked: `ostd/src/mm/dma`); in the kernelet build those paths are not taken and `prepare_dma` and `unprepare_dma` are no-ops. A tenant that hands a device a frame it does not own gets the request failed, not a fault. There is no IOMMU on this path and no passthrough of physical devices in this design; passthrough would need an IOMMU domain per kernelet and is left for the Limitations chapter.

## What the host must undo

The memory the host holds for a kernelet, and what destroy does with each ([Faults, termination, and reclamation](../faults-and-reclamation.md)):

| what | where the host keeps it | at destroy |
|---|---|---|
| the runs | the grant table and the owner array; each run is a host `Segment` | each `Segment` dropped, which returns its frames to the host allocator one frame at a time as `Segment::drop` does on the tree; owner-array entries cleared; the host's own `MetaSlot`s for the run's frames are intact, since no kernelet ever wrote them |
| registered roots | the root set | forgotten; the frames are in the grant |
| the window's level-3 table and the host-mapped subtrees | `window_l3` | the level-2 and level-1 tables under `KW_TEXT`, `KW_DATA` and `KW_SHARED` freed; the level-2 tables under `KW_HEAP` are reserved grant frames and go with their runs |
| the data template copy, the replicas, the shared pages, the radix leaves | host frames | freed |
| the kind's shared text frames | the image | reference count decremented; freed when no kernelet of the kind remains and the image is unregistered |

Nothing per frame is reset, because the host's frame metadata was never the kernelet's to write.

## Costs

- Per grain: 32 KiB of metadata (1.56 percent); one level-2 entry. Per run: one grant-table append, the radix writes, and, after boot, one `JOB_GRANT` wakeup and one pass over the new entries. Per 512 slots of coverage: one reserved level-2 frame.
- Per metadata access: two dependent loads in the shared radix and one in the run table, instead of one shift and add; `paddr_to_vaddr` is the same; `vaddr_to_paddr` is one load fewer. *Estimated*: under ten cycles each; the Evaluation chapter measures the allocation path against native.
- Per first activation of an address space: one crossing; per activation: one crossing and the CR3 write, which also drops the window's translations (register A2, **[unverified]** cost).
- Per remote TLB flush batch: one crossing and one IPI per target CPU per operation, bounded by the kernelet's CPU set and the tree's 32-operation batch.
- The memory floor of a kernelet is `initial_grains × 2 MiB` plus the fixed host-side items of the [control half](../kernelet-api-control.md). *Estimated* at 8 grains plus 4 per virtual CPU, from the initial slabs and the buddy allocator's per-virtual-CPU pools; to be measured, and the pools' hoarding tuned if it dominates.
- Fragmentation of the host's allocator by aligned, contiguous requests; if a run cannot be had, the grant fails rather than falling back.

## What a tenant sees

`/proc/meminfo`'s total is the initial grant, since the kernel proper computes it once from `boot_info().memory_regions` at boot (checked on the tree: `kernel/core/src/vm/mod.rs`, `mem_total`); later grants raise the free memory the allocator reports but not the total, as a balloon does on Linux. `MemFree` sums the buddy allocator's per-CPU counters over `all_cpus()`, which is virtualized to the kernelet's virtual CPUs, so it is right only because that row of the [taxonomy](index.md) holds. `ENOMEM` and the OOM killer behave as in the host kernel, at the grant limit instead of the machine's. Physically contiguous allocations larger than the largest run the host can supply fail with `ENOMEM`; on the tree that affects overlay file-system copy-up of large files and `ext2` mount of large volumes. Everything else in the memory system is the host kernel's behavior.

## What this page decides

- **Metadata at the head of the run** (register D13, revised): in-grant metadata that dies with the run, one contiguous range behind it. The alternative, a separate metadata region of the window, needs its own tables, a bootstrap for the first chunk, and a second mapping per grain.
- **The host bootstraps memory at creation, and the grant table and radix are host-written shared pages** (register D10, revised, and D29). The alternative, the kernelet building its own tables from a descriptor list, has no memory to build them in before the first grain is mapped, and would have to write the host's level-3 table to hook its own level-2 tables. Host-written tables cost the host a few frames per kernelet and cost the kernelet nothing.
- **Memory is granted in contiguous runs** (register D30). Single grains would cap a kernelet's largest contiguous allocation at under 2 MiB, which the kernel proper's own file systems exceed; runs move the limit to the host's fragmentation, which is where it is for any kernel.
- **Page-table nodes are addressed through the window like every other frame.** The earlier decision D14, a linear-map exception for them, is withdrawn: with the host bootstrapping the first run, nothing needs it.
