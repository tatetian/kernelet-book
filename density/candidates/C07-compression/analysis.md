# C07: Compressed idle memory

**Status:** adopted for the 50 ms tier. **Depends on kernelets:** no; hosts compress swapped VM memory with `zswap` too. **Acts on:** `P_proc` and `m_kproc` of idle sandboxes when NVMe is too slow for the tier.

## The problem

At the 50 ms tier a wake must not wait for NVMe: a 60 MiB working set is 30 ms of sequential read at 2 GB/s before the faults, and a record that misses costs 100 µs per random 4 KiB read. Idle memory must stay in DRAM, and DRAM is the bound. Compression trades CPU for space: an idle sandbox's private pages are compressed in place, and a wake decompresses its working set at memory speed.

## The mechanism

The eviction path of C03 gets a second target beside NVMe: a per-host compressed pool (Linux's `zswap`/`zsmalloc` shape) that stores each 4 KiB page compressed, indexed by the swap entry the window's page-table entry holds. A refault decompresses one page in about 1–2 µs at LZ4 speeds; a wake that prefetches the recorded working set of 60 MiB decompresses it at 2–4 GB/s per core, 15–30 ms on one core, or a few milliseconds spread over several. The pool is charged to the kernelet it holds pages for, so a sandbox with incompressible private data is simply a bigger sandbox.

## Gain

Measured on the resident kernel-plus-Python snapshot's nonzero pages, per-page `zlib` level 1: 59.6 MiB → 22.5 MiB, **2.64×** (`../../benchmark/results/firecracker-raw.md`). LZ4 compresses somewhat less than `zlib` level 1 but is what the pool would use for speed; the literature on `zswap` for anonymous memory reports 2–4×. Taking **2.5×**: an idle sandbox's 60 MiB of private state becomes 24 MiB of DRAM at the 50 ms tier, on top of the `m_fixed` that stays uncompressed.

## Evidence

- Measured: 2.64× on 15,247 nonzero pages of a resident Python guest; the pages are kernel state, Python's heap and its cached file data, so a heap-only ratio is unverified and the model uses 2.5×.
- Published: `zswap` and `zram` ratios of 2–4× on anonymous memory in kernel documentation and in the compression-for-idle-VM literature; the same trick is available to a host holding idle VM memory, which is why the candidate is generic.

## Isolation

None: the pool holds the kernelet's own pages, charged to it, freed at destroy; compressed pages are not shared across kernelets, so no deduplication side channel exists.

## Cost

- CPU: one compression per evicted page (~2 µs LZ4) and one decompression per refault or prefetched page; 10,000 sandboxes evicting 60 MiB each once per idle period of 10 minutes is 25 MB/s of compression, a fraction of one core.
- DRAM: the compressed pool itself, `P_proc / 2.5` per idle sandbox.

## Changes to the Blueprint

Recorded here, not applied: the compressed pool as a second eviction target in the endovisor's policy; nothing in vOSTD.
