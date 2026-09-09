# C07: Compressed idle memory

**Status:** adopted for the 50 ms tier, revised after review. **Depends on kernelets:** no; a host can `zswap` an idle VM's memory. Counted against platforms that keep idle sandboxes warm; at technique parity it is a wash. **Acts on:** the private pages of idle sandboxes when NVMe is too slow for the tier.

## The mechanism

C03's eviction gets a second target beside NVMe: a per-host compressed pool (Linux's `zswap`/`zsmalloc` shape) that stores each 4 KiB page compressed. The kernelet's reclaim thread (C02, C03) swaps pages out to a swap device the endovisor backs with the pool instead of a file; a refault decompresses one page in 1–2 µs at LZ4 speed. The argument for the pool at the 50 ms tier is the **miss** cost, not the bandwidth: a page the wake record did not predict costs ~90 µs as a random NVMe read and ~2 µs as a decompression, so a wake with a thousand misses is 90 ms against 2 ms. The pool is charged to the kernelet it holds pages for, so a sandbox with incompressible private data is a bigger sandbox. Page-table frames and pinned device buffers are never in the pool (they are not evicted, C03).

## Gain

Measured on the resident kernel-plus-Python snapshot's nonzero pages, per-page `zlib` level 1: 59.6 MiB → 22.5 MiB, **2.64×**. The review pointed out that this sample is mostly not what C07 compresses (23 MiB of it is cached file data that C01 removes, ~14 MiB kernel state, ~10 MiB of free-list residue, and only 12 MiB of heap) and that LZ4 reaches about 0.75–0.8 of `zlib` level 1's ratio (LZ4's own Silesia figures: 2.10 against 2.74), so the LZ4 ratio corresponding to the measurement is about 2.0–2.2×. The model uses **2.0×** until an anonymous-pages-only measurement exists (dumping the runtime's page frame numbers through `/proc/<pid>/pagemap` in the guest and compressing those offsets of the snapshot with LZ4 is the experiment). Published fleet averages for compressed far memory (Google's fleet-wide zswap, ASPLOS 2019; Meta's TMO, ASPLOS 2022) are 2–4× on anonymous memory including zero pages.

An idle sandbox's private state after C01, `m_kproc + F_written + P_proc` = 165 MiB in the model, becomes about **83 MiB** of pool at 2.0×, plus `m_fixed`; the first draft omitted the written file pages from this figure.

## Cost

- CPU: compressing 10,000 sandboxes' 60–165 MiB once per 10-minute idle period is **1–2.7 GB/s**, 2–6 cores of LZ4 at 450–700 MB/s per core, plus decompression on wake; the first draft's "25 MB/s, a fraction of one core" was off by 40×. This cost is subtracted from the CPU bound at the 50 ms tier in the composition.
- DRAM: the pool itself, private state over 2.0 per idle sandbox.
- Wake budget at 50 ms: the recorded working set (24 MiB) decompressed and mapped before delivery, 6–12 ms on one core at 2–4 GB/s plus ~0.3 µs per page of pool lookup, then job delivery and the agent's own first response. A 60 MiB set is 16–31 ms and leaves little for the agent; a `zstd` pool with its higher ratio decompresses at 1–1.5 GB/s and does not fit the tier at 60 MiB. So the tier binds the record size, not the ratio.

## Evidence

- Measured: 2.64× (`zlib` level 1) on 15,260 nonzero pages of a resident Python guest, which bounds the LZ4 heap ratio at about 2×; the heap-only ratio is **[unverified]**.
- Published: fleet compression ratios above; LZ4 and `zstd` speeds from their own benchmarks.

## Isolation

None: the pool holds the kernelet's own pages, charged to it, freed at destroy; compressed pages are not shared across kernelets, so no deduplication side channel exists.

## Changes to the Blueprint

Recorded here, not applied: the compressed pool as a backing for the swap device model in the endovisor's policy; nothing in vOSTD beyond C03's.
