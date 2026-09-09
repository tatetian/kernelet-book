# The density benchmark

This directory defines what "sandbox density" means for the rest of `density/`, states the workload model and its parameters, gives the measurement procedure, and records the baseline numbers with their provenance. Every candidate in `../candidates/` is scored against the model defined here.

## 1. What density means

**Density** is the number of sandboxes one server can hold at a stated service level. Two numbers are reported, on one hypothetical server, at three wake tiers:

| number | definition |
|---|---|
| **resident density** | sandboxes created and reachable, in whatever state the platform keeps an idle sandbox, such that a message to any of them gets a first response within the tier's wake bound |
| **active density** | sandboxes doing work at the same instant, each with its working set resident and its CPU share available |

Wake tiers: **≤ 50 ms**, **≤ 500 ms**, **≤ 5 s** from a message arriving at an idle sandbox to its first response. The tier decides how much of an idle sandbox may be evicted from DRAM, so it decides resident density.

Four resources are modeled separately and the smallest bound wins:

- **Memory.** `D_mem = M_usable / m̄`, where `m̄` is the mean DRAM a sandbox holds in the state mix of the tier.
- **CPU.** `D_cpu = C / (a · c_active + (1 − a) · c_idle)`, cores over the mean per-sandbox demand, with `a` the active fraction.
- **Storage.** Snapshot and root-image bytes per sandbox against local NVMe, and the read bandwidth a wake consumes against the wake rate.
- **Network and host kernel objects.** Threads, file descriptors, page-table frames per sandbox against the host's limits.

Memory is the binding resource for every system measured here (§4), so the model is written out for memory and the others are checked as constraints.

## 2. The server

A common server of today, not a next-generation one: 2 sockets, 64–128 physical cores, **1 TiB DRAM** of which **900 GiB** is taken as usable by sandboxes after the host's own needs, NVMe local storage, no CXL. The target of 10,000 sandboxes on it is a per-sandbox budget of **92 MiB** of DRAM and **~1.3 % of a core**, all in.

## 3. The workload model

An agent sandbox is a full Linux user space (Python or Node toolchain, git, shell) with one resident agent process, idle at least 90 % of the time, whose work is a burst of short CPU activity and file-system activity, occasionally a browser. Its life is a cycle: create, work, idle (long), wake, work, …, and finally delete.

Per-sandbox memory is decomposed into components that the candidate optimizations act on separately:

| symbol | component | what it is | baseline value (§4) | notes |
|---|---|---|---|---|
| `m_fixed` | fixed per-sandbox host cost | VMM process private memory, host kernel objects, second-level page tables | 1.0–1.5 MiB | measured, snapshot-restored idle VM |
| `m_boot` | guest kernel boot residue | pages the guest kernel touched at boot and never returns | 45 MiB cold-booted; ~0 private after snapshot restore (shared) | measured |
| `m_kproc` | kernel-private working state | guest-kernel slab, page tables, structures written after restore | part of `m_burst_priv` | measured together with the burst |
| `m_file` | file data the sandbox has read | copies of file pages in the guest page cache | grows to whatever is read, 250 MiB after one toolchain read; never returned without guest reclaim | measured |
| `m_proc` | process anonymous memory | the agent runtime's heap and stacks | 12 MiB (minimal Python with common modules); a real agent runtime is a **parameter**, 30–150 MiB | measured / parameter |
| `m_shared` | pages shared across sandboxes | read-only pages served from one copy (snapshot page cache, image page cache, kernel text) | amortized to ~0 per sandbox | measured: `Shared_Clean` |

Parameters without a local measurement are marked and can be substituted:

- `P_proc`: the agent runtime's private anonymous memory when idle after work. Default **60 MiB** (between the minimal Python measured at 12 MiB and a Node-based agent, which public dashboards show at 100–200 MiB when active).
- `F`: file bytes a sandbox reads over its life (toolchain, dependencies, repository). Default **300 MiB**; one read of the Ubuntu toolchain directories here was 205 MiB.
- `a`: active fraction, default **0.1**.
- `w`: wake rate across the fleet, default 10,000 sandboxes × one wake per 10 minutes = **17 wakes/s**.

## 4. The baseline: Firecracker microVMs, measured

Host: Intel Xeon E3-1270 v6 (4 cores, 8 threads), 31 GiB, Linux 6.8.0-100, Firecracker v1.16.1, guest kernel 6.1.128 with Firecracker's CI configuration, root file system Ubuntu 24.04 (Firecracker's CI squashfs, read-only). Scripts are in `scripts/`, raw output in `results/`. Every number is the host's view (`/proc/<pid>/smaps_rollup` of the Firecracker process, plus `/proc/meminfo` deltas) unless marked *guest*.

| experiment | result |
|---|---|
| **cold boot, idle** (1 vCPU, 128 MiB, `sleep` as init) | RSS **47.2 MiB**, of which anonymous 44.7 MiB; 4 threads; host `SecPageTables` +120 KiB, `PageTables` +108 KiB. *Guest:* 109 MiB total, 91 MiB free, 4.8 MiB cached. So **~40 MiB of guest memory is touched by boot alone** and stays host-resident. |
| **snapshot of the idle VM** | 8,546 nonzero pages = **33.4 MiB** touched; create 476 ms; restore **35 ms** |
| **two VMs restored from that snapshot, idle** | each RSS 9.8 MiB, **Pss 6.2 MiB, Private_Dirty 0.86 MiB**, Shared_Clean 7.3 MiB; unchanged after 25 s idle |
| **Python agent resident** (256 MiB; Python 3.12 with json, re, ssl, http.client, subprocess, asyncio, logging, argparse, pathlib imported) | RSS **71.3 MiB**; *guest:* 12.0 MiB anonymous, 23.2 MiB cached. Snapshot: 59.6 MiB touched; restore 18–36 ms; two restores idle: **Private_Dirty 0.86 MiB each**, Shared_Clean 8.9 MiB |
| **toolchain read** (guest reads every file under `/usr/lib`, `/usr/bin`, `/usr/share` once, 205 MiB) | RSS **245 MiB** and stays; *guest:* 204 MiB cached, 5 MiB free. The host already holds the same file data in its own page cache: **every byte a VM reads is held twice**, and the guest never gives it back. |
| **same, with the balloon's free-page reporting** | after the read: identical, 244–246 MiB (page cache is not free memory; data integrity confirmed by in-guest hashes; snapshot 222 MiB nonzero). After the *guest* drops its caches and compacts: RSS **75.8 MiB within 5 s**. So the host can get the memory back, but only when the guest chooses to free it, which an idle guest does not; forcing it means balloon inflation, which the Firecracker documentation calls CPU-intensive. |
| **work burst after restore** | see `results/firecracker-raw.md` |

Published figures, for cross-checking:

- Firecracker's own specification: VMM overhead ≤ 5 MiB per microVM (1 vCPU, 128 MiB); "thousands" per host; oversubscription of 10–20× in production.
- Nanvix (arXiv 2604.11669, Fig. 9b), instances per 1 GiB on a 32 GiB host: Firecracker cold-booted **20** (≈ 51 MiB each), Cloud Hypervisor 9, Unikraft 18, gVisor 43, **Firecracker from snapshot 104** (≈ 9.8 MiB), Nanvix 134, Hyperlight 552, a process 1,646.
- REAP (ASPLOS 2021, Fig. 4): a booted function instance holds **100–200 MB**; after snapshot restore its working set is **8–99 MB, 24 MB on average**, 3–39 % of the booted footprint; the Firecracker/guest infrastructure accounts for up to 8 MB of that.
- Squeezy (EuroSys 2026, §6.3): one function per microVM costs **2.53×** the memory of the same function as a container inside a shared VM.
- Fly.io Sprites: idle microVMs hibernate to disk, memory not preserved, wake in about a second; E2B pauses to a memory snapshot.

## 5. Where the baseline's density is bounded

Putting the measurements into the model for the default workload, per microVM after it has done its first burst of work:

| state | private DRAM per VM | how it arises |
|---|---|---|
| idle, just restored from a golden snapshot | ~1.5 MiB | `m_fixed`; everything else is shared page cache of the snapshot |
| idle after one work burst, no reclaim | `m_fixed` + `m_kproc` + `F` + `P_proc` ≈ 1.5 + ~10 + 300 + 60 ≈ **370 MiB** | file data copied into the guest page cache and kept; the runtime's heap |
| idle after one burst, host inflates the balloon to reclaim | `m_fixed` + `m_kproc` + `P_proc` ≈ **70 MiB**, minus what swapping the heap out would save | costs guest CPU and a latency hit on the next wake |
| hibernated to disk | 0 DRAM, `F + P_proc + m_kproc` on NVMe | restore 35 ms plus faulting the working set back |

So the baseline has three separate bounds:

1. **Warm tier (≤ 50 ms):** the idle VM must stay in DRAM with its working set. Without reclaim, `m̄ ≈ 370 MiB` gives **~2,500 per server**; with aggressive balloon reclaim, `m̄ ≈ 70 MiB` gives **~13,000** in principle, but each reclaim is a guest-side pressure event and the next wake re-reads the toolchain from disk. This is the regime the "1,000–2,000 per server" figures describe.
2. **Cold tier (≤ 5 s):** idle VMs can be hibernated; DRAM holds only the active ones, `a · 370 MiB`, giving **~24,000** by memory, and the bound moves to restore throughput and NVMe: at 17 wakes/s and ~60 MiB working set per wake, 1 GB/s of reads.
3. **The 500 ms tier** sits between: an idle VM must keep enough in DRAM for a sub-second wake, which the balloon-reclaimed state does not guarantee (the toolchain re-read alone is several hundred milliseconds from NVMe).

The bottleneck in every tier is the same quantity: **private copies of data the host already has** (file pages, and after a restore the guest kernel's own copies of what the snapshot shared), plus the inability to return memory without the guest's cooperation. That is what the candidates attack.

## 6. Measurement procedure

1. Boot one microVM with `scripts/fc-run.sh <name> <mem_mib> <vcpus> <initrd>`; the initramfs is built by `scripts/mkinitrd.sh <name> <command-file>` around a static busybox and runs the command inside the read-only Ubuntu root.
2. Read the host's view with `scripts/fc-measure.sh <name>` (`smaps_rollup` and `/proc/meminfo` deltas) and the guest's view from the captured console.
3. Snapshot with the Firecracker API, count nonzero 4 KiB pages in the memory file, restore into two processes and compare `Pss`, `Shared_Clean` and `Private_Dirty`.
4. Never more than a handful of instances; total under 8 GiB of memory and 20 GiB of disk.

## 7. What is not measured here

No Node-based agent (the CI image has none; `P_proc` is a parameter), no network path, no multi-vCPU VMs, no scale run. The Asterinas kernel was booted once under QEMU with the tree's test initramfs (2 GiB, debug build): 128 MiB used after boot of which 79 MiB is the unpacked initramfs, 6 MiB slab (`results/asterinas-2g-guest-meminfo.txt`); a debug-build upper bound, not a kernelet figure.
