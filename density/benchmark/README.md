# The density benchmark

This directory defines what "sandbox density" means for the rest of `density/`, states the workload model and its parameters, gives the measurement procedure, and records the baseline numbers with their provenance. Every candidate in `../candidates/` is scored against the model defined here. The first version of this page was reviewed; the corrections are applied and noted where they change a number.

## 1. What density means

**Density** is the number of sandboxes one server can hold at a stated service level. Two numbers are reported, on one hypothetical server, at three wake tiers:

| number | definition |
|---|---|
| **resident density** | sandboxes created and reachable, in whatever state the platform keeps an idle sandbox, such that a message to any of them gets a first response within the tier's wake bound |
| **active density** | sandboxes doing work at the same instant, each with its working set resident and its CPU share available |

Wake tiers: **≤ 50 ms**, **≤ 500 ms**, **≤ 5 s** from a message arriving at an idle sandbox to its first response. The tier decides how much of an idle sandbox may leave DRAM, so it decides resident density.

Four resources are modeled and the smallest bound wins:

- **Memory.** `D_mem = M_usable / (a · m_active + (1 − a) · m_idle)`, with `a` the active fraction and `m` the per-sandbox DRAM in each state.
- **CPU.** `D_cpu = C / (a · c_active + (1 − a) · c_idle)`; `c_idle` is measured at 0.03 % of a core for a VM and taken as 0 for a kernelet, a 3 % term the tables round away.
- **Storage.** Evicted state and root images per sandbox against NVMe capacity; wake reads and eviction writes against its bandwidth and endurance.
- **Host kernel objects.** Threads and page-table frames per sandbox.

## 2. The server

A common server of today, not a next-generation one: 2 sockets, **128 physical cores**, **1 TiB DRAM** of which **900 GiB** is taken as usable by sandboxes, NVMe at 2 GB/s, no CXL. The target of 10,000 sandboxes is a per-sandbox budget of **92 MiB** of DRAM and **1.28 % of a core**, all in. A 256-core part is shown where it matters.

## 3. The workload model

An agent sandbox is a full Linux user space with one resident agent process, idle at least 90 % of the time; its work is a burst of short CPU activity and file-system activity. Per-sandbox memory is decomposed into components the candidates act on separately:

| symbol | component | baseline value | provenance |
|---|---|---|---|
| `m_fixed` | VMM or kernelet object, host kernel objects, page tables, stacks | **6 MiB** (VM); 2 MiB (kernelet, estimated) | Pss of a restored idle VM is 6.2 MiB; Nanvix measures 9.8 MiB per snapshot-restored instance by `MemAvailable` delta; the first draft's 1.5 MiB was `Private_Dirty` alone |
| `m_boot` | guest kernel boot residue | 45 MiB cold; 0 private after a snapshot restore | measured |
| `m_kproc` | kernel state written after restore | ~10 MiB (VM); ~5 MiB (kernelet) **[unverified]** | not separable in the burst measurement; a modeling choice |
| `F_public` | file pages read from the shared image | **200 MiB** (range 23–199 measured) | Python runtime 23 MiB, Node.js 52 MiB, whole-tree sweep 199 MiB |
| `F_written` | file pages the tenant wrote (installs, repository, caches) | **100 MiB** (parameter) | not measured; depends on whether dependencies are baked into the image |
| `P_proc` | the runtime's private heap | **60 MiB** (parameter; 8–12 MiB measured idle, 140–400 MB reported for busy Node agents) | `py256`, `node256`; public reports for Claude Code and OpenClaw |
| `a` | active fraction | 0.1 | not measured |
| `c_active` | CPU of an active sandbox | 0.1 core | not measured; the ratio's most sensitive parameter |
| VM size | the guest's configured memory, which caps `F_public + F_written + P_proc` through the guest's own LRU | 512 MiB | a platform choice; a 256 MiB guest trimmed its cache to 164 MiB in the burst test |

## 4. The baseline: Firecracker microVMs, measured

Host: Intel Xeon E3-1270 v6 (4 cores, 8 threads), 31 GiB, Linux 6.8.0-100, Firecracker v1.16.1, guest kernel 6.1.128 with Firecracker's CI configuration (no `virtio-pmem`, no DAX), root file system Ubuntu 24.04 (Firecracker's CI squashfs, read-only). Scripts are in `scripts/`, raw output in `results/`. Every number is the host's view (`/proc/<pid>/smaps_rollup` of the Firecracker process, plus `/proc/meminfo` deltas) unless marked *guest*. All sizes are MiB (kB ÷ 1024).

| experiment | result |
|---|---|
| **cold boot, idle** (1 vCPU, 128 MiB, `sleep` as init) | RSS **46.1 MiB**, of which anonymous 43.6 MiB; 4 threads; host `SecPageTables` +120 KiB. *Guest:* 109 MiB total, 91 MiB free, 4.7 MiB cached: **~40 MiB of guest memory is touched by boot alone** and stays host-resident. |
| **snapshot of the idle VM** | 8,546 nonzero pages = **33.4 MiB**; create 476 ms; restore 35 ms wall time |
| **two VMs restored from that snapshot, idle** | each RSS 9.7 MiB, **Pss 6.1 MiB**, Private_Dirty 0.84 MiB, Shared_Clean 7.3 MiB; unchanged after 25 s |
| **Python agent resident** (256 MiB; Python 3.12 with a dozen common modules) | RSS **69.6 MiB**; *guest:* 11.7 MiB anonymous, 22.7 MiB cached. Snapshot 59.6 MiB touched; restore 18–36 ms; two restores idle: Private_Dirty 0.84 MiB each |
| **Node.js agent resident** (256 MiB; Node 22 with `fs`, `http`, `https`, `crypto`, `child_process` and others loaded, a timer alive) | RSS **96.6 MiB**; *guest:* 8.2 MiB anonymous, 51.3 MiB cached (its 118 MB binary). Snapshot 87.3 MiB touched; restore 11–32 ms; two restores idle: Private_Dirty 0.86 MiB each |
| **toolchain read** (guest reads every file under `/usr/lib`, `/usr/bin`, `/usr/share` once, 205 MiB) | RSS **244.7 MiB** and stays; *guest:* 199.5 MiB cached. The host already holds the same image in its page cache: **every byte a VM reads through `virtio-blk` is held twice**, and the guest never gives it back. |
| **same, balloon with free-page reporting** | after the read: identical (data integrity confirmed by in-guest hashes); after the *guest* drops its caches and compacts: RSS **75.8 MiB within 5 s**, the same with `page_reporting_order=4` (76.4 MiB). The host gets freed memory back fast; it cannot get in-use memory (an idle guest's page cache) without balloon inflation. |
| **work burst after restore** (Python resident; restore; read the Python library, `/usr/bin` and the C libraries; allocate and touch 30 MiB) | Private_Dirty **187.4 MiB** per VM afterward (164 MiB of it guest page cache in a 256 MiB guest that trimmed its cache to fit), Shared_Clean 31.8 MiB |
| **idle CPU** | `sleep` guest: ≤ 0.03 % of a core (2 ticks in 60 s); Node.js guest with a live timer: **0.033 %** (39 ms of `schedstat` CPU in 120 s), host `halt_poll_ns` 200 µs |
| **CPU per operation** (guest vs host, same Python script) | first-touch page fault **4.43 vs 2.06 µs** (2.15×); faults on backed guest memory 1.88 vs 1.99 µs; `getpid` 627 vs 626 ns |
| **compressibility** | nonzero pages of the Python snapshot, `zlib` level 1 per page: 2.64× (mixed kernel, heap and file pages) |

Published figures, for cross-checking:

- Firecracker: VMM overhead ≤ 5 MiB per microVM; "thousands" per host; production oversubscription of 10–20×, which is only possible when guests' memory is not resident. Since v1.14 a `virtio-pmem` device with DAX: the documentation reports a 128 MB VM booting from it at ~96 MB RSS with DAX against ~120 MB without, and recommends DAX "to avoid unnecessary duplication of data in guest page cache".
- Nanvix (arXiv 2604.11669, Fig. 9b), instances per 1 GiB: Firecracker cold-booted **20**, gVisor 43, **Firecracker from snapshot 104** (≈ 9.8 MiB each), Hyperlight 552, a process 1,646.
- REAP (ASPLOS 2021, Fig. 4): a booted function instance holds **100–200 MB**; after snapshot restore its working set is **8–99 MB, 24 MB on average**.
- Squeezy (EuroSys 2026, §6.1.1): virtio-mem hot-unplug of 2 GiB takes 2.5 s, 61 % page migration and 24 % zeroing; with allocation segregation about 125 ms.
- Platforms: Fly.io Machines autosuspend to a Firecracker snapshot and resume "in a few hundred milliseconds"; Fly.io Sprites inflate the balloon on idle; AWS Lambda freezes idle environments and restores SnapStart snapshots in tens of milliseconds; E2B keeps a sandbox warm until its timeout (5 minutes by default) and otherwise kills or, on request, pauses it (about 1 s to resume).

## 5. Where the baseline's density is bounded

The baseline is not one number but a **ladder** of what a VM platform does with idle sandboxes, and the study reports the kernelet against each rung:

| rung | what it means | warm sandbox | idle sandbox at 500 ms | idle at 50 ms | idle at 5 s |
|---|---|---|---|---|---|
| **keep-warm** | idle VMs stay resident with their working set (E2B inside its timeout; any platform answering under 500 ms without a restore) | `6 + 10 + 200 + 100 + 60` = **376 MiB** | 376 | 376 | 0 (killed or paused, ~1 s resume) |
| **swap-capable** | the host pages idle guests out (`madvise`, or suspend with lazy restore and a prefetch record; Fly.io) | 376 | `6 + 24` hot = **30** | `6 + 24 + 346/2` (`zswap`) = **203** | 0 |
| **DAX + swap** | as above with `virtio-pmem` or `virtiofs` DAX so that image pages are not copied (Cloud Hypervisor, Kata with DAX on, Firecracker ≥ 1.14 with a DAX-capable guest) | `6 + 10 + 4 + 100 + 60` = **180** | 30 | `6 + 24 + 150/2` = **105** | 0 |

For the keep-warm rung the bottleneck is private copies of data the host already has (file pages, 200 of 376 MiB) plus the guest's inability to return memory without cooperation; for the other rungs memory stops binding and CPU does, at `128 / (0.1 × 0.1) = 12,800` sandboxes for the default agent.

## 6. Measurement procedure

1. `scripts/fetch-assets.sh` downloads the pinned Firecracker release, guest kernel, root image and busybox (`ASSETS.sha256`).
2. `scripts/mkinitrd.sh <name> <command-file>` builds an initramfs that runs the command inside the read-only root; `scripts/fc-run.sh <name> <mem> <vcpus> <initrd> [balloon] [extra_drive]` boots one microVM; `scripts/fc-measure.sh` reads the host's view; the guest's view is in the captured console.
3. `scripts/fc-snapshot.sh <name>` snapshots, counts nonzero pages (`count-nonzero.py`, with `--compress` for the ratio), restores two copies and compares `Pss`, `Shared_Clean` and `Private_Dirty`; `scripts/idle-cpu.sh` sums per-thread `schedstat`.
4. Never more than two instances at a time; under 8 GiB of memory and 20 GiB of disk in total.

## 7. What is not measured here

`F_written`, `a` and `c_active` (parameters); a DAX guest (the CI kernel has no `virtio-pmem`); multi-vCPU VMs; the network path; any kernelet number (nothing of the design has run). The Asterinas kernel was booted once under QEMU with the tree's test initramfs (2 GiB, debug build): 128 MiB used after boot of which 79 MiB is the unpacked initramfs, 6 MiB slab (`results/asterinas-2g-guest-meminfo.txt`), a debug-build upper bound for the kernel proper's boot residue.
