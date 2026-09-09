# Sandbox density: the scheme and what the evidence supports

*A study of whether kernelets could hold 5–10× more agent sandboxes per server than microVM sandboxes, with the evidence that exists short of an implementation. The benchmark, the baseline measurements and the model are in [`benchmark/`](benchmark/README.md); every candidate optimization ever considered is one line in [`candidates.md`](candidates.md), with its analysis under `candidates/<id>/`. Every candidate and the composition were reviewed by skeptical reviewers, and this page states what survived.*

## The answer in one paragraph

Against microVM sandboxes **as they are kept warm today**, the composed scheme reaches **5.2× on a 128-core server and 9.3× on a 256-core one at the 500 ms wake tier**, and 3.6× at the 50 ms tier: a warm Firecracker sandbox holds 376 MiB of host memory after one burst of work, most of it a private copy of image files the host already has, and a platform that must answer in under half a second without a snapshot restore keeps that resident for every idle sandbox, which bounds it at about 2,500 per server. The kernelet scheme brings the warm footprint to 171 MiB by sharing image pages instead of copying them (C01), pages idle sandboxes out cooperatively to about 26 MiB (C03 over C13 and C02), and leaves the host CPU, not DRAM, as the binding resource at about 12,800 sandboxes on 128 cores. Against a VM platform that **already pages out or suspends idle sandboxes** (Fly.io does, in a few hundred milliseconds), the gain at the 500 ms tier is **1.0–1.35×**, because both systems are then bound by the same CPU and the residual is the kernelet's lower CPU per operation (C14); against one that also has DAX, the warm-tier gain is about 1.1×. At the 5 s tier, where everything can hibernate, the ratio is 1.0× and the kernelet's advantage is wake cost and storage, not count. **The 5–10× target is met only against keep-warm practice; at technique parity the ceiling is about 1.4×, and the reason is that every large memory saving in the scheme is available to a VM stack too, at a mechanism cost the kernelet avoids but a density count does not see.**

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
| idle, 500 ms tier | 376 (keep-warm) or 30 (swap-capable: fixed + 24 MiB hot) | 30 | **26** (2 + 24 hot) | C03, C13 |
| idle, 50 ms tier | 376 or 203 (`zswap` at 2×) | 105 | **98.5** (2 + 24 hot + 145/2) | C07 |
| idle, 5 s tier | 0 (suspended) | 0 | 2 | C03 |

## Density by tier

`D_mem = 921,600 MiB / (a · m_warm + (1 − a) · m_idle)`; `D_cpu = 128 / (a · c_active) = 12,800` (25,600 on 256 cores); the density is the smaller. C07's compression costs 2–6 cores at the 50 ms tier, taken as 4.

| tier | VM keep-warm | VM swap-capable | VM DAX + swap | kernelet | ratio vs keep-warm (128 / 256 cores) | ratio vs swap-capable | vs DAX + swap |
|---|---|---|---|---|---|---|---|
| ≤ 50 ms | 2,451 | 4,183 | 8,192 | 8,711 (memory) → 8,711 | **3.6× / 3.6×** | 2.1× | 1.06× |
| ≤ 500 ms | 2,451 | 14,266 → **12,800** (CPU) | 20,480 → 12,800 | 22,756 → **12,800** | **5.2× / 9.3×** (22,756 is the memory bound on 256 cores) | 1.0× (1.6× on 256 cores) | 1.0× (1.1×) |
| ≤ 5 s | 24,511 → 12,800 | 12,800 | 12,800 | 48,762 → 12,800 | 1.0× | 1.0× | 1.0× |

The CPU-per-operation candidate (C14) shifts the CPU-bound rows: a VM pays 2.15× on first-touch page faults (measured) and an exit per I/O completion, so for an agent whose active CPU is 10–30 % such work the VM's bound is 9,500–11,600 against the kernelet's 12,800, a **1.1–1.35×** residual at technique parity (fraction unverified).

## Where the ratio comes from, and where it goes

`D_cpu = cores / (a · c_active)`; the memory bound of the scheme at 500 ms is 22,756, so kernelets are CPU-bound whenever `a · c_active > 0.0056` on 128 cores; the keep-warm VM is memory-bound whenever `a · c_active < 0.052`. The ratio against keep-warm is `min(D_cpu, 22,756) / 2,451`:

| `a · c_active` | 0.005 | 0.01 | 0.02 | 0.05 | 0.1 |
|---|---|---|---|---|---|
| kernelet, 128 cores | 22,756 | 12,800 | 6,400 | 2,560 | 1,280 |
| kernelet, 256 cores | 22,756 | 22,756 | 12,800 | 5,120 | 2,560 |
| VM keep-warm | 2,451 | 2,451 | 2,451 | 2,451 | 1,280 |
| ratio, 128 / 256 | 9.3 / 9.3 | 5.2 / 9.3 | 2.6 / 5.2 | 1.0 / 2.1 | 1.0 / 1.0 |

So the 5–10× holds against keep-warm practice for agents that average 1 % of a core or less over their life, which is an agent that waits on a model most of the time; a `pytest` or `npm install` burst once per ten-minute cycle is already 2–5 %. Against a swap-capable VM platform the ratio is 1.0× at every cell of this table on 128 cores and up to 1.6× on 256 cores, plus C14's 1.1–1.35×.

## What is kernelet-specific, honestly

| candidate | kernelet-specific? | what it changes |
|---|---|---|
| C01 shared image pages | the *mechanism* (no EPT, no DAX window); the *saving* is DAX's | 200 of the 205 MiB removed from a warm sandbox; the largest term, and available to DAX-capable VM stacks |
| C13 relocatable memory | yes: a second naming of memory without a second-level walk | makes C03, C05 and hibernation sound; revises the Blueprint's D58 |
| C02 cooperative return | the mechanism (same allocator both sides); the saving is free-page reporting's | 0–5 MiB; the prerequisite of C03 |
| C04 lean fixed cost | yes, a correction to the Blueprint | 9–13 MiB → 2 MiB; parity with a restored VM's 6–10 |
| C14 CPU per operation | yes | 1.1–1.35× on the CPU bound for fault-heavy agents |
| C06 idle CPU | yes | ≤ 3 cores per 10,000; below the model's resolution |
| C03 eviction, C05 templates, C07 compression | no | the idle-tier and creation-time savings, which VM platforms have |

## What the scheme needs that does not exist

In the kernel proper: a memory-reclaim subsystem (page-cache LRU, reverse mappings, a reclaim thread, anonymous-page swap-out), which the tree lacks entirely and which C02 and C03 depend on; a process checkpoint restorer for C05. In vOSTD: kernelet-physical addresses (C13), the borrowed-frame rules and constructor (C01), a per-spawn stack size (C04). In the endovisor: the image arena, the swap device and compressed pool, the eviction policy, deadline heaps for `timer_arm` (C06). Each is listed on its candidate page under "Changes to the Blueprint".

## Storage and wake budget

Per idle sandbox on NVMe at the 500 ms and 5 s tiers: 165 MiB (kernelet: `m_kproc + F_written + P_proc`) against 376 MiB (a VM's touched pages), 1.45 TiB against 3.3 TiB for 9,000 idle sandboxes. Wake reads at 17/s × 24 MiB (the recorded set) are 0.4 GB/s; eviction writes are about the same and need the compressed pool or a clean-page swap cache to stay within a drive's endurance.

## What is unverified

- `F_written`, `a`, `c_active` and the fraction of active CPU in fault-heavy work: parameters, not measurements; they decide every ratio above.
- `m_kproc` on both sides (10 and 5 MiB are modeling choices); the kernelet's `m_fixed` (2 MiB, analytic); the hot set of 24 MiB (REAP's average for functions, not agents).
- The compression ratio of an agent's heap alone (2.0× is bounded from a mixed sample).
- Every kernelet mechanism: nothing of the design has run.
- Whether the kernel proper's system-call paths are restartable for a kernel-level clone (C05's deferred variant).

## Changes the scheme needs in the Blueprint

Recorded, not applied, from the candidate pages: register D58 revised to kernelet-physical addresses with a p2m and `page_table::*` virtualized at entry writes and queries (C13); an image arena, an `Image` owner state, a per-kernelet borrow table, `image_map`/`image_unmap`, the borrowed-frame rules and `Frame::from_borrowed` (C01); assumption A1 withdrawn, `grains_release`, `Kernelet::shrink`, `JOB_SHRINK`, the window unmap-and-flush path and metadata retention (C02); a swap device model, an idle signal, wake records (C03); 4 KiB `KW_DATA`, per-spawn 64–96 KiB stacks, the grant counted as tenant memory, the Tasks and Control pages' "512 KiB, measured on the tree" corrected to the tree's build settings (C04); the runtime's create flow restoring a process checkpoint (C05); `idle_tick_hz = 0` and a deadline heap for `timer_arm` (C06); a compressed pool (C07).

## Status

Baseline measured; nine candidates written and reviewed, seven adopted (three of them as prerequisites or corrections rather than gains), three rejected or deferred; composition computed against a ladder of three baselines. The exit criterion, 5–10× at the 500 ms and 5 s tiers with every counted gain evidenced, is **met at the 500 ms tier against keep-warm practice only** (5.2× on 128 cores, 9.3× on 256), **not at the 5 s tier**, and **not against a platform that already pages out or suspends idle sandboxes**, where the ceiling is about 1.4× from CPU per operation. The candidate space for memory has been exhausted by the reviews: once idle sandboxes leave DRAM on both sides, no memory technique changes the count, and the only remaining lever is CPU per unit of tenant work, which is C14's 1.1–1.35×.

## Log

- 2026-09-09: benchmark defined; Firecracker baseline measured (cold boot, snapshot restore, Python and Node.js resident, toolchain read, free-page reporting at two orders, work burst after restore, idle CPU by `schedstat`, per-operation CPU microbenchmarks, compressibility); literature read (Firecracker, its pmem and balloon documentation, Nanvix, REAP, Squeezy, Memory Matters, virtiofs DAX, KSM side channels, Fly.io, E2B, Lambda); candidates C01–C14 listed, C01–C07, C13, C14 written; seven reviews applied: C03 and C05 found unsound under the Blueprint's physical naming and redesigned over C13; the baseline restated as a ladder; the headline restated against each rung.
