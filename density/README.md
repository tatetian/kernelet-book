# Sandbox density: the scheme

*A study of how kernelets could hold 5–10× more agent sandboxes per server than microVM sandboxes do today, with the evidence that exists short of an implementation. The benchmark and baseline are in [`benchmark/`](benchmark/README.md); every candidate optimization ever considered is one line in [`candidates.md`](candidates.md), with its analysis under `candidates/<id>/`.*

## The claim in one paragraph

A microVM sandbox that has done any work holds, privately, a copy of every file it read (150–300 MiB for an agent's toolchain), its guest kernel's boot residue and working state, and its runtime's heap, and it cannot give any of it back without the guest's cooperation; measured here, a Firecracker guest that read 205 MiB of files held **245 MiB** of host memory afterward and kept it while idle. That is why microVM platforms run one to two thousand warm sandboxes per server. A kernelet's memory is host-owned, mapped by the host, and indexed by physical address, which lets the host share the page cache into it instead of copying (C01), take frames back at grain granularity without a balloon (C02), page idle sandboxes out and in on ordinary host page faults (C03), clone a pre-booted template copy-on-write (C05), and leave an idle sandbox costing nothing in CPU (C06). With the Blueprint's own fixed cost brought down to a VM's (C04), the composed scheme brings a sandbox's memory after a work burst from **372 MiB to 87 MiB** and its idle memory at the 500 ms wake tier to **4.5 MiB**, which on a common 1 TiB server is a memory bound of **72,000 resident sandboxes** against the baseline's **2,500**. The binding constraint then moves from memory to CPU, at about 12,800 resident sandboxes for an agent that is active a tenth of the time at a tenth of a core; that is where the next-generation CPU count enters. Against microVMs as deployed the gain at the 50 ms and 500 ms tiers is **5.2× on today's cores and 10× on 256-core parts**; at the 5 s tier, where microVMs can hibernate too, both are CPU-bound and the kernelet's advantage is in wake cost and storage, not count.

## The model

Per-sandbox DRAM is the sum of components (`benchmark/README.md`, §3), each with a baseline value measured on Firecracker and a value under the scheme:

| component | baseline VM (as deployed) | kernelet with the scheme | candidate |
|---|---|---|---|
| `m_fixed`: VMM or kernelet object, host kernel structures, tables, stacks | 1.5 MiB (measured, restored VM) | 1.5 MiB (from the Blueprint's 34 MiB) | C04 |
| `m_boot`: guest kernel boot residue | 0 after snapshot restore (33–45 MiB shared) | 0 (clone) | C05 |
| `m_kproc`: kernel working state written after restore | ~10 MiB (part of the 192 MiB private after a burst) | ~5 MiB, returned as freed | C02, C04 |
| `m_file`: file pages read, public part | 280 MiB (of `F` = 300; measured 168–205 MiB per read pass) | **0**, borrowed from the host page cache | C01 |
| `m_file`: file pages written (tenant data) | 20 MiB | 20 MiB | |
| `P_proc`: the runtime's private heap | 60 MiB (parameter; 12 MiB measured for minimal Python) | 60 MiB | |
| **after a work burst, warm** | **372 MiB** | **87 MiB** | |
| idle at the 50 ms tier | 372 MiB (no reclaim in practice) | 1.5 + (60 + 5) / 2.5 = **27.5 MiB** | C07 |
| idle at the 500 ms tier | 372 MiB | 1.5 + 3 MiB kept hot = **4.5 MiB** | C03 |
| idle at the 5 s tier | 0 (hibernated to disk, restore 35 ms + faults) | 0 | C03, C05 |

Server: 900 GiB usable of 1 TiB; 128 cores; active fraction `a = 0.1`; `c_active = 0.1` core per active sandbox; wake rate 17/s.

## Density by tier

`D_mem = 900 GiB / (a · m_active + (1 − a) · m_idle)`; `D_cpu = 128 / (a · c_active) = 12,800`; the density is the smaller.

| tier | baseline VM, as deployed | kernelet, the scheme | ratio | on a 256-core server |
|---|---|---|---|---|
| ≤ 50 ms | memory: 921,600 / 372 = **2,480** | memory: 921,600 / (8.7 + 24.8) = 27,500; CPU 12,800 → **12,800** | **5.2×** | 25,600 vs 2,480: **10.3×** |
| ≤ 500 ms | **2,480** (idle VMs stay warm) | memory: 921,600 / (8.7 + 4.1) = 72,000; CPU → **12,800** | **5.2×** | **10.3×** |
| ≤ 5 s | memory: 921,600 / 37.2 = 24,800; CPU → **12,800** | memory 106,000; CPU → **12,800** | 1.0× | 1.0× |

Two honest qualifications. First, the 500 ms row's baseline assumes what platforms do: keep warm VMs warm. A VM stack could inflate balloons on idle (idle VM 72 MiB, density 9,000) or host-swap idle guests (density up to the same CPU bound), at the cost of a guest-side pressure cycle per idle transition and a 150 ms toolchain re-read per wake; candidates C03 and C07 are marked generic for that reason. What no VM stack short of `virtiofs` DAX can do is C01, and C01 is the largest single term: without it an active sandbox costs 372 MiB and the memory bound at any tier with a tenth of the sandboxes active is 24,800, not 72,000. Second, the CPU bound is the same for both systems at the parameters chosen, so the ratio at the warm tiers is "memory-bound baseline against CPU-bound kernelets"; the phase diagram below says where that holds.

## Where CPU binds

`D_cpu = cores / (a · c_active)`. The memory bound of the scheme at the 500 ms tier is 72,000, so the kernelet side is CPU-bound whenever `a · c_active > 128 / 72,000 = 0.0018` on 128 cores, which is every realistic agent; the baseline is memory-bound whenever `a · c_active < 128 / 2,480 = 0.052`, which is every agent that spends less than half a core when active and is active less than a tenth of the time. Between those, the ratio is `min(D_cpu, 72,000) / 2,480`:

| `a · c_active` | 0.005 | 0.01 | 0.02 | 0.05 | 0.1 |
|---|---|---|---|---|---|
| kernelet, 128 cores | 25,600 | 12,800 | 6,400 | 2,560 | 1,280 |
| kernelet, 256 cores | 51,200 | 25,600 | 12,800 | 5,120 | 2,560 |
| baseline (memory-bound at 2,480 until CPU binds) | 2,480 | 2,480 | 2,480 | 2,480 | 1,280 |
| ratio, 128 / 256 cores | 10.3 / 20.6 | 5.2 / 10.3 | 2.6 / 5.2 | 1.0 / 2.1 | 1.0 / 1.0 |

So the 5–10× holds for agents that average 1 % of a core or less over their life, which is an agent that waits on a model most of the time; for compute-heavy agents both systems are CPU-bound and the case for kernelets is per-operation cost, not density.

## What is kernelet-specific and what is not

| candidate | kernelet-specific? | share of the warm-tier gain |
|---|---|---|
| C01 shared file pages | yes (DAX-like sharing without an EPT; Firecracker has no `virtiofs`) | 280 of the 285 MiB removed from an active sandbox |
| C02 cooperative return | yes (same allocator on both sides; no balloon) | keeps `m_kproc` a working set; removes 28 MiB of stranding per reclaim |
| C04 lean fixed cost | yes (a correction to the Blueprint) | brings `m_fixed` to the VM's 1.5 MiB; without it the idle figure is 36 MiB and the scheme fails |
| C06 idle CPU | yes | 3 cores per 10,000 idle |
| C03 host paging | no (KVM guests are swappable) | idle 87 → 4.5 MiB; cheaper wake (no VMM, no EPT) |
| C05 template clone | no (snapshot restore) | `m_boot` → 0; cheaper (no VMM restore) |
| C07 compression | no (`zswap`) | idle 65 → 26 MiB at the 50 ms tier |

## Storage and wake budget

Per idle sandbox on NVMe at the 500 ms and 5 s tiers: 65 MiB (kernelet) against 372 MiB (VM hibernated), 585 GB against 3.3 TB for 9,000 idle sandboxes, plus shared root images. Wake reads at 17/s × 60 MiB = 1 GB/s, a third of one NVMe device; the same for a VM stack that hibernates, plus its 35 ms restore.

## What is unverified

- `P_proc` for a real agent runtime (Node-based agents in particular); `F` for a real agent's life; `a` and `c_active` from production traces. All three are parameters of the model; the tables above use 60 MiB, 300 MiB, 0.1 and 0.1.
- The kernelet fixed cost of 1.5 MiB after C04 is analytic, from the Blueprint's inputs; nothing of the kernelet has run.
- C01's borrowed-frame mechanism and C03's sleeping page-in on the kernelet's fault path are designs recorded here, not reviewed against the tree.
- The compression ratio (2.6×) was measured on a snapshot that mixes kernel state, heap and cached file data; the heap-only ratio may differ.
- The 5 s tier's equality assumes a VM platform actually hibernates idle VMs and re-reads their working sets; platforms that do (Fly.io, E2B) report second-scale wakes.

## Changes the scheme needs in the Blueprint

Recorded, not applied, from the candidate pages: a borrowed read-only owner state and two service calls (C01); `grains_release`, `on_memory_pressure`, `JOB_SHRINK` and the withdrawal of assumption A1 (C02); a swap-entry case in the fault handler before the kill rule, an idle signal on the control half, wake records (C03); `KW_DATA` at 4 KiB copy-on-write pages, lazily backed 64 KiB kernel stacks, a one-grain refill and per-virtual-CPU pool sizing (C04); a template owner state with reference counts, `Kernelet::clone`, `KERNELET_CLONE` and the agent's uniqueness hook (C05); `timer_arm` required and `idle_tick_hz = 0` (C06); a compressed eviction target (C07).

## Status

Baseline measured; seven candidates analyzed, five adopted as kernelet-specific or as necessary companions; composition computed; reviews pending (see the log below).

## Log

- 2026-09-09: benchmark defined; Firecracker baseline measured (cold boot, snapshot restore, Python resident, toolchain read, free-page reporting, work burst after restore); literature read (Firecracker, Nanvix, REAP, Squeezy, Memory Matters, virtiofs DAX, KSM side channels); candidates C01–C12 listed, C01–C07 written; composition computed.
