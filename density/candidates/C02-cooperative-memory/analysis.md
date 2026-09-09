# C02: Host-owned frames, cooperative return

**Status:** adopted as a prerequisite of C03 and C05, revised after review; standalone gain 0–5 MiB, analytic. **Depends on kernelets:** yes in mechanism (the same allocator code on both sides, a call instead of a balloon protocol); the *saving* is generic, since free-page reporting and virtio-mem give a VM most of it. **Acts on:** the memory a sandbox holds but no longer uses.

## The problem, measured, and what the measurement does not show

A VM's memory only grows from the host's point of view unless the guest reports free pages. With Firecracker's balloon and free-page reporting, after a 256 MiB guest freed 200 MiB of page cache (`drop_caches` plus `compact_memory`), host RSS fell from 244 MiB to **75.8 MiB within 5 s** (`../../benchmark/results/firecracker-raw.md`, `fpr`), against 46.1 MiB for a cold-booted 128 MiB guest. The first draft called the 30 MiB difference "stranded fragments"; the review showed most of it is ordinary in-use kernel memory of a larger guest after a workload (its `MemTotal − MemFree` was 24 MiB against 18 MiB, and 2 MiB more is reserved outside `MemTotal`), and a rerun with `page_reporting.page_reporting_order=4` instead of the default order 9 gave the same 76.4 MiB (`fpr4`), so the reporting granularity is not what holds the rest. Free-page reporting returns what the guest frees, and returns it fast. What it cannot return is memory the guest still holds: its page cache, which an idle guest keeps, and memory the guest kernel considers in use. Forcing that needs balloon inflation, a guest-side pressure event, and Squeezy (EuroSys 2026, §2.2, §6.1.1) measures the other direction, hot-unplug, at 2.5 s per 2 GiB with virtio-mem, 61 % of it page migration and 24 % zeroing, and shows a partition-aware guest bringing it to about 125 ms. So a VM stack *can* reclaim quickly; what it needs is a guest whose allocator keeps short-lived memory together.

## The mechanism

In the Blueprint every frame a kernelet has is a host-owned grain, and assumption A1 says memory only grows because reclaiming needs the kernelet's cooperation. The cooperation is one call and one job:

- `grains_release(kpaddr, count)`: the kernelet returns whole grains it no longer uses. It is made by a **kernelet-side reclaim thread**, not from the allocator's free path: the tree's frame allocator frees under `disable_local` and, for the global pool, under a spin lock, from every context including inside the kernel proper's own locks (`osdk/deps/frame-allocator/src/lib.rs`), which is no place for a crossing that zeroes 2 MiB. The reclaim thread wakes on a free-memory high-water threshold and on the shrink job, pulls order-9 chunks out of the per-CPU and global pools under their locks, drops the locks, and releases them. The host unmaps the grain from the window, **flushes the window translation on every CPU in the kernelet's set**, clears the owner-array and p2m entries (C13), and returns the frame; the eight metadata frames of the grain stay mapped and are reset to unused, since the allocator's coalescing probes a buddy's metadata slot and an unmapped slot is a kernel-mode fault that kills the kernelet.
- `Kernelet::shrink(target_grains)` on the control half, legal in `Running`, posts `JOB_SHRINK`; the worker only wakes the reclaim thread, since a worker's delivery holds the preemption count and reclaim sleeps on page locks and writeback. A hook in the other direction (`on_memory_pressure`) was the first draft's mistake: hooks run from the kernelet into the endovisor.
- **The kernel proper needs a reclaim subsystem it does not have.** On the tree the page cache has no eviction ("as we have not implemented any related mechanisms", `kernel/core/src/vm/page_cache/mod.rs`), no reverse mapping from page to VMO, no LRU, no reclaim thread and no swap; `JOB_SHRINK` today would reach a kernel with nothing to run. C02 therefore requires: a page-cache LRU with reverse mappings, a reclaim thread with a target, and, for C03, anonymous-page swap-out to a host-provided device. That is the same feature Linux has and the kernel proper lacks, and it is the largest single piece of kernel-proper work in this study; until it exists, C02 returns only what already reaches the allocator free: exited processes' memory, freed slabs, truncated files.

Grain-granular return has the same fragmentation problem Linux has at order 9: one live 4 KiB page pins 2 MiB. Asterinas has no page migration or compaction, so after a churn its free memory is at least as fragmented across grains as Linux's; Squeezy's answer, keeping short-lived allocations in regions of their own so that whole regions empty out, applies to the kernel proper's allocator as much as to a guest's. Nothing here measures how many whole grains a kernelet frees after a burst.

## Gain

In the composition C02 enters only through `m_kproc`, kept a working set rather than a high-water mark, **0–5 MiB per sandbox, analytic, unverified**; the first draft's 10–30 MiB was not derived from anything, and the 28 MiB "stranding" it claimed to remove was a misreading. Its real role is as the prerequisite that makes C03 and C05 clean: a paged-out or cloned kernelet never carries dead grains, and under A1 a transient 200 MiB compile would be held by a kernelet forever while a VM with free-page reporting gives it back.

## Evidence

- Measured: free-page reporting recovers dropped guest cache within 5 s at both reporting orders (`fpr`, `fpr4`); balloon inflation is the only path for in-use guest memory.
- Published: Squeezy's reclamation figures and its diagnosis (allocation segregation, not host ownership, makes reclamation fast).
- Analytic: a returned grain is 2 MiB reusable at once, for one call, one flush across the kernelet's CPUs, and one 2 MiB zeroing at the next grant (D55; the first draft zeroed twice).

## Isolation

The window unmap must complete its cross-CPU flush before the frame is returned: until then a stale translation would let the releasing kernelet read a frame the host may have re-granted. That flush is a new host path, shared with C03's eviction, and it is what makes "none" true; the Memory page's statement that window mappings are never unmapped while a kernelet lives (register A1) is withdrawn with A1. A kernelet can release only grains the owner array says are its own and that are not pinned by a device model in flight.

## Cost

- Per released grain: the reclaim thread's work, one crossing, one cross-CPU flush, 32 KiB of metadata kept mapped; the next grant's zeroing.
- The reclaim subsystem in the kernel proper, and a host-side unmap-and-flush path.

## Changes to the Blueprint

Recorded here, not applied: assumption A1 withdrawn; `grains_release` on the service table; `Kernelet::shrink` on the control half and `JOB_SHRINK`; the grant table becomes a table with holes, with its reader protocol restated; the window unmap-and-flush path; metadata retention for released grains; a reclaim subsystem in the kernel proper (LRU, reverse mappings, reclaim thread, swap-out for C03).
