# Sandbox density: the scheme and what the evidence supports

*A study of whether kernelets could hold 5–10× more agent sandboxes per server than microVM sandboxes, with the evidence that exists short of an implementation. The benchmark, the baseline measurements and the model are in [`benchmark/`](benchmark/README.md); every candidate optimization ever considered is one line in [`candidates.md`](candidates.md), with its analysis under `candidates/<id>/`. Every candidate and the composition were reviewed by skeptical reviewers, and this page states what survived. [`bounds.md`](bounds.md) derives, from first principles, the density no scheme can exceed on this server and workload, and measures the composition against it.*

## The answer in one paragraph

Against microVM sandboxes **kept warm in DRAM**, the composed scheme reaches **5.2× on a 128-core server and 8.4–9.3× on a 256-core one at the 500 ms wake tier**, and 3.5× at the 50 ms tier. That rung of the baseline is a hypothetical, not a named platform's practice for long-lived agents (E2B kills at its timeout, Fly.io suspends, Lambda snapshots): a warm Firecracker sandbox is modeled at 376 MiB of host memory after one burst of work (measured 187–245 MiB in a 256 MiB guest), most of it a private copy of image files the host already has, and a platform that must answer in under half a second without a restore keeps that resident for every idle sandbox, which bounds it at about 2,500 per server. The kernelet scheme brings the warm footprint to 171 MiB by sharing image pages instead of copying them (C01), pages idle sandboxes out cooperatively to 26–31 MiB (C03 over C02), and leaves the host CPU, not DRAM, as the binding resource at about 12,800 sandboxes on 128 cores. Against a VM platform that **already pages out idle sandboxes incrementally** (dirty pages only, as host swap or a diff snapshot does), the gain at the 500 ms tier is **1.0× on 128 cores**, times the kernelet's lower CPU per operation where CPU binds (C14: 1.1–1.3× against non-hugepage VMs, 1.0–1.1× at parity), and 1.4–1.6× on 256 cores, where the VM is memory-bound and the kernelet is not; against one that also has DAX, 1.0× on 128 cores and 1.0–1.1× on 256. A platform that suspends by writing a sandbox's whole memory per idle cycle (Fly.io's suspend) is bound by the drive, not DRAM: about 2,600 sandboxes per 2 GB/s drive by bandwidth and about 400 per 3 DWPD drive by wear, at one wake per ten minutes, so the scheme is 5× against it by bandwidth alone on one drive and about 16× with wear counted on both sides at one or two drives each (8× at four); dirty tracking on that platform's side closes the gap. At the 5 s tier, where everything can hibernate, the ratio at parity is 1.0× (assuming incremental hibernation on the kernelet side, which C13 lists) and the kernelet's advantage is wake cost and storage, not count; against whole-memory suspend it is the same 5× as at 500 ms. **The 5–10× target is met only against rungs that keep idle sandboxes resident or rewrite their whole memory per cycle; at technique parity the ceiling is 1.0–1.1× on 128 cores and, on 256 cores, 1.8–2.0× against a swap-capable platform without DAX and 1.25–1.4× against one with DAX, times an unmeasured kernel-path ratio between Asterinas and Linux (the bounds of [`bounds.md`](bounds.md), which no scheme can exceed; the composition reaches 1.4–1.6× and 1.0–1.1×). The reason is that every large memory saving in the scheme is available to a VM stack too, at a mechanism cost the kernelet avoids but a density count does not see.**

## The model

Per-sandbox DRAM components (`benchmark/README.md`, §3), default parameters: `F_public` 200 MiB, `F_written` 100, `P_proc` 60, active fraction `a` 0.1, `c_active` 0.1 core, 900 GiB usable, 128 cores.

| component | VM, keep-warm | VM, DAX | kernelet, the scheme | candidate |
|---|---|---|---|---|
| `m_fixed` | 6 (measured Pss; Nanvix 9.8) | 6 | 2 (estimated) | C04 |
| `m_kproc` | 10 [unverified] | 10 | 5 [unverified] | C02, C04 |
| `F_public` private copy | 200 | 4 | 4 (2 % residue) | C01 |
| `F_written` | 100 | 100 | 100 | |
| `P_proc` | 60 | 60 | 60 | C05 shares the initial state on both sides |
| **warm, after a burst** | **376** | **180** | **171** | |
| idle, 500 ms tier | 376 (keep-warm) or 30 (swap-capable: fixed + 24 MiB hot) | 30 | **26–31** (2 + 5 kernel state a guest-side reclaimer cannot evict + 24 hot, less kernel pages within the hot set) | C03, C02 |
| idle, 50 ms tier | 376 or 203 (`zswap` at 2×) | 105 | **99** (2 + 5 + 24 hot + 136/2) | C07 |
| idle, 5 s tier | 0 (suspended) | 0 | 2 (hibernation over C13; 7 without it) | C03, C13 |

## Density by tier

`D_mem = 921,600 MiB / (a · m_warm + (1 − a) · m_idle)`; `D_cpu = 128 / (a · c_active) = 12,800` (25,600 on 256 cores); the density is the smaller. C07's compression costs 2–6 cores at the 50 ms tier, taken as 4.

| tier | VM keep-warm | VM swap-capable | VM DAX + swap | kernelet | ratio vs keep-warm (128 / 256 cores) | ratio vs swap-capable (128 / 256) | vs DAX + swap (128 / 256) |
|---|---|---|---|---|---|---|---|
| ≤ 50 ms | 2,451 | 4,183 | 8,192 | 8,678 (memory) | **3.5× / 3.5×** | 2.1× / 2.1× | 1.06× / 1.06× |
| ≤ 500 ms | 2,451 | 14,266 → **12,800** (CPU) | 20,480 → 12,800 | 20,480–22,756 → **12,800** | **5.2× / 8.4–9.3×** (the memory bound on 256 cores; the drive's bandwidth does not bind, since the hot set stays resident and only the dirty set is written, but its wear needs about four 3 DWPD drives at that density: `bounds.md` §2.4) | 1.0× / 1.4–1.6× | 1.0× / 1.0–1.1× |
| ≤ 5 s | 24,511 → 12,800 | 12,800 | 12,800 | 48,762 → 12,800 | 1.0× | 1.0× | 1.0× |

The CPU-per-operation candidate (C14) multiplies the CPU-bound cells: a VM without hugepage-backed guest memory pays 2.0× on first-touch page faults (4.43 µs measured against the kernelet's estimated 2.2), so for an agent whose active CPU is 10–30 % such work the VM's bound is 9,850–11,600 against the kernelet's 12,800, **1.1–1.3×** (fraction unverified); with hugepage backing, which is technique parity, the residual is **1.0–1.1×**.

## Where the ratio comes from, and where it goes

`D_cpu = cores / (a · c_active)`; the memory bound of the scheme at 500 ms is 20,480–22,756, so kernelets are CPU-bound whenever `a · c_active > 0.006` on 128 cores; the keep-warm VM is memory-bound whenever `a · c_active < 0.052`. The ratio against keep-warm is `min(D_cpu, D_mem) / 2,451`:

| `a · c_active` | 0.005 | 0.01 | 0.02 | 0.05 | 0.1 |
|---|---|---|---|---|---|
| kernelet, 128 cores | 20,480–22,756 | 12,800 | 6,400 | 2,560 | 1,280 |
| kernelet, 256 cores | 20,480–22,756 | 20,480–22,756 | 12,800 | 5,120 | 2,560 |
| VM keep-warm | 2,451 | 2,451 | 2,451 | 2,451 | 1,280 |
| ratio, 128 / 256 | 8.4–9.3 / 8.4–9.3 | 5.2 / 8.4–9.3 | 2.6 / 5.2 | 1.0 / 2.1 | 1.0 / 1.0 |

So the 5–10× holds against the keep-warm rung for agents that average 1 % of a core or less over their life, which is an agent that waits on a model most of the time; a `pytest` or `npm install` burst once per ten-minute cycle is already 2–5 %. Against a swap-capable VM platform (its memory bound 14,266) the ratio is 1.0× on 128 cores for `a · c_active ≥ 0.01`, and up to 1.4–1.6× where the VM is memory-bound and the kernelet is not: at `a · c_active = 0.005` on 128 cores, or at 0.01 on 256 cores. C14's factor multiplies these.

## What is kernelet-specific, honestly

| candidate | kernelet-specific? | what it changes |
|---|---|---|
| C01 shared image pages | the *mechanism* (no EPT, no DAX window); the *saving* is DAX's | 196 of the 200 MiB of public file pages removed from a warm sandbox; the largest term, and available to DAX-capable VM stacks |
| C13 relocatable memory | yes: a second naming of memory without a second-level walk | enables hibernation (5 s tier), the kernel-level clone and C08; bounds C03's page tables; revises the Blueprint's D58 |
| C02 cooperative return | the mechanism (same allocator both sides); the saving is free-page reporting's | 0–5 MiB; the prerequisite of C03 |
| C04 lean fixed cost | yes, a correction to the Blueprint | 9–13 MiB → 2 MiB; parity with a restored VM's 6–10 |
| C14 CPU per operation | yes | 1.1–1.3× on the CPU bound for fault-heavy agents against non-hugepage VMs; 1.0–1.1× at parity |
| C06 idle CPU | yes | ≤ 3 cores per 10,000; below the model's resolution |
| C03 eviction, C05 templates, C07 compression | no | the idle-tier and creation-time savings, which VM platforms have |

## What the scheme needs that does not exist

In the kernel proper: a memory-reclaim subsystem (page-cache LRU, reverse mappings, a reclaim thread, anonymous-page swap-out), which the tree lacks entirely and which C02 and C03 depend on; a process checkpoint restorer for C05. In vOSTD: kernelet-physical addresses in the PTE codec (C13), the borrowed-frame rules and constructor (C01), a per-spawn stack size (C04). In the endovisor: the image arena, the swap device and compressed pool, the eviction policy, the host page-table walk for whole-kernelet moves (C13), deadline heaps for `timer_arm` (C06). Each is listed on its candidate page under "Changes to the Blueprint".

## Storage and wake budget

Per idle sandbox on NVMe at the 500 ms and 5 s tiers: 165 MiB (kernelet: `m_kproc + F_written + P_proc`, the `m_kproc` term only with C13's hibernation) against 376 MiB (a VM's touched pages; Fly.io writes a Machine's whole memory), 1.42 TiB against 3.23 TiB for 9,000 idle sandboxes. With the hot set resident, wake reads are the record's misses only; eviction writes are the dirty set, 24 MiB per sandbox per ten-minute cycle **[unverified]**, 512 MiB/s at 12,800 sandboxes (21 wakes per second), which is 46 TB per day, 6 drive writes per day on one 7.68 TB drive: the server needs up to two 3 DWPD drives at 12,800 and up to four at the 256-core density, or half that with the compressed pool halving the bytes written; the 24 MiB assumes every dirtied page is evicted and rewritten each cycle, an upper bound (`bounds.md` §2.4). Bandwidth is not the limit (one drive at 0.27 utilization at 12,800, about 0.45 at the 256-core density); wear is.

## What is unverified

- `F_written`, `a`, `c_active` and the fraction of active CPU in fault-heavy work: parameters, not measurements; they decide every ratio above. The dirty set per idle cycle (24 MiB) and the wake interval (ten minutes), which decide the drive's utilization (about 0.5 on one drive at the 256-core density) and its wear (6–11 drive writes per day on one drive; two to four drives at 3 DWPD).
- `m_kproc` on both sides (10 and 5 MiB are modeling choices); the kernelet's `m_fixed` (2 MiB, analytic); the hot set of 24 MiB (REAP's average for functions, not agents); how much of the hot set is kernel pages (the 26–31 range).
- The compression ratio of an agent's heap alone (2.0× is bounded from a mixed sample).
- The kernelet's first-touch fault cost (2.2 µs, estimated) and the VM's with hugepage backing (not measured; THP state unrecorded on both sides of the existing measurement).
- Every kernelet mechanism: nothing of the design has run.
- Whether the kernel proper's system-call paths are restartable for a kernel-level clone (C05's deferred variant), and the host copy-on-write path that clone needs (C13).

## Changes the scheme needs in the Blueprint

Recorded, not applied, from the candidate pages: register D58 revised to kernelet-physical addresses (D13's naming with D58's mapping): a bounds-checked p2m in `KW_SHARED`, the m2p index in each entry's ignored bits, the PTE codec virtualized, a host page-table walk for whole-kernelet moves, the release path's root-wide flush, A13 relieved (C13); an image arena, an `Image` owner state, a per-kernelet borrow table, `image_map`/`image_unmap`, the borrowed-frame rules and `Frame::from_borrowed` (C01); assumption A1 withdrawn, `grains_release`, `Kernelet::shrink`, `JOB_SHRINK`, the window unmap-and-flush path and metadata retention (C02); a swap device model, an idle signal, wake records (C03); 4 KiB `KW_DATA`, per-spawn 64–96 KiB stacks, the grant counted as tenant memory, the Tasks and Control pages' "512 KiB, measured on the tree" corrected to the tree's build settings (C04); the runtime's create flow restoring a process checkpoint (C05); `idle_tick_hz = 0` and a deadline heap for `timer_arm` (C06); a compressed pool (C07).

## Status

Baseline measured; nine candidates written and reviewed and all nine adopted (three as prerequisites, corrections or enablers rather than gains: C02, C04, C13; one as a sensitivity: C14); two rejected on the isolation floor (C09, C10), one deferred (C08), two folded into C04 (C11, C12); composition computed against a ladder of three baselines. The exit criterion, 5–10× at the 500 ms and 5 s tiers with every counted gain evidenced, is **met at the 500 ms tier against the keep-warm rung only** (5.2× on 128 cores, 8.4–9.3× on 256), **not at the 5 s tier**, and **not against a platform that already pages out idle sandboxes incrementally**, where the ceiling is 1.0–1.1× on 128 cores and 1.8–2.0× (without DAX) or 1.25–1.4× (with DAX) on 256, from the first-principles bounds of `bounds.md`, which also shows that no scheme can do better at parity on this server and workload. One memory candidate the bounds analysis revealed remains uncomposed: C15, a tiered idle state at the 50 ms tier, which would lift both sides to the CPU bound if the wake record's misses fit the tier; it changes no parity ratio. Once idle sandboxes leave DRAM on both sides, no memory technique changes the count, and the only remaining lever is CPU per unit of tenant work, which is C14's.

## Log

- 2026-09-09: benchmark defined; Firecracker baseline measured (cold boot, snapshot restore, Python and Node.js resident, toolchain read, free-page reporting at two orders, work burst after restore, idle CPU by `schedstat`, per-operation CPU microbenchmarks, compressibility); literature read (Firecracker, its pmem and balloon documentation, Nanvix, REAP, Squeezy, Memory Matters, virtiofs DAX, KSM side channels, Fly.io, E2B, Lambda); candidates C01–C14 listed, C01–C07, C13, C14 written; seven reviews applied: C03 and C05 found unsound under the Blueprint's physical naming and redesigned; the baseline restated as a ladder; the headline restated against each rung. An eighth review of C13, C14 and the composition applied: C13's translation point moved to the PTE codec and its reverse map into the entry bits, a host walk added for whole-kernelet moves, and its "makes C03 sound" claim withdrawn; C14's upper end restricted to non-hugepage VMs and its I/O term dropped; the kernelet's 500 ms idle figure raised to 26–31 MiB for the kernel state a guest-side reclaimer cannot evict; the Lambda citation corrected; the keep-warm rung marked hypothetical.
- 2026-09-09, later: `bounds.md` written in a write-and-revise loop (`BOUNDS_LOG.md`): per-resource floors, the bound per tier and rung, the composition as a fraction of it, the candidate-space coverage table; it added the drive as a resource, C15, and the whole-memory-suspend rung, and it found that the 5 s tier assumes incremental hibernation and that drive wear, not bandwidth, is the storage limit (two to five 3 DWPD drives), which makes the ratio against a whole-memory-suspend platform depend on the drives each side is given.
