# C04: A lean fixed cost per kernelet

**Status:** adopted, revised after review; a correction to the Blueprint, not a gain over the baseline. **Depends on kernelets:** yes. **Acts on:** `m_fixed`, the host memory a sandbox costs before it does anything.

## The Blueprint as written, re-added

Counted from the Blueprint's own pages, for a one-vCPU sandbox. The thread count comes from the tree: a one-vCPU kernel proper spawns the boot task, `softirqd`, two work-queue monitors and their on-demand workers, `devtmpfsd`, one network poll thread per interface (loopback and `virtio-net`), one `virtio-blk` thread, plus vOSTD's worker, ten to eleven kernel-side threads before any tenant thread; a Python agent adds one to three and a shell, a Node agent adds the main thread, four V8 platform threads, four libuv threads and the inspector. So 13 threads (Python-sized) or 21 (Node-sized).

| item | Blueprint today | per sandbox |
|---|---|---|
| `KW_DATA`: the writable data template, padded to one 2 MiB page (Builds and images) | 2 MiB private frames | 2.0 MiB |
| kernel stacks: every kernelet task is a host thread with a fully backed stack | the Blueprint says 512 KiB "measured on the tree", which is `DEFAULT_STACK_SIZE_IN_PAGES = 128`, the crate's fallback; the tree's own `Makefile` sets 64 pages (256 KiB) for debug and **8 pages (32 KiB)** for release builds on x86-64 | 13 × 512 KiB = 6.5 MiB (Python), 10.5 MiB (Node); 0.4 / 0.7 MiB with the tree's release stack |
| frame metadata: 8 host frames per granted grain, 1.56 % | at the 24 MiB initial grant | 0.4 MiB |
| window page tables, task records, shared pages, `Kernelet` object, device inbox | a few frames | 0.15 MiB |
| **host-side `m_fixed`** | | **9–13 MiB** (3 MiB with the tree's release stack) |
| the initial grant, `initial_grains`, 8 grains plus 4 per virtual CPU (Memory, *estimated*) | 24 MiB, zeroed eagerly at grant (D55) and never returned (A1) | tenant memory, not fixed cost: it is the sandbox's RAM, where `m_kproc` and the early `P_proc` live |

The first draft counted the grant in `m_fixed` and reached 34 MiB; that double-counted it against `m_kproc`. What is kernelet-specific about the grant is that D55 makes it resident at once where a VM's guest memory is populated lazily, and A1 keeps it; C02 and C05 address those, not a constant.

## The changes

1. **`KW_DATA` at 4 KiB granularity.** The template's used part is under 128 KiB plus 2 KiB per virtual CPU (Builds and images, *estimated* from the tree's measured `.data`, `.bss` and `.cpu_local`); mapping it with private 4 KiB frames instead of one padded 2 MiB page gives **0.15–0.2 MiB** with no fault path. Copy-on-write from the template, which the first draft proposed, saves at most the never-written 50 KiB and is what C05 supplies anyway; it is dropped from C04. Register A2 wanted the single 2 MiB entry for translation refill after a CR3 write; the refill of tens of 4 KiB data pages costs 1–3 µs per process switch, *estimated*, on top of an A2 that is itself unverified.
2. **Small, fully backed kernel stacks.** The first draft's demand-backed stacks are not feasible on x86-64: a push into an unbacked page is a double fault, not a page fault, and returning from a double fault into the faulting instruction is undefined; and a service call from a thread whose stack had grown into unbacked pages would fault in host code at depth one, which the Blueprint treats as a machine halt. The feasible change is a per-spawn stack size, fully backed with the existing guard pages: the tree already runs the whole Linux ABI, drivers and softirq rounds on **32 KiB** in release builds, so a kernelet thread's stack is that plus the service half's reserve (A3, 64 KiB *estimated*, to be measured; the tree's 32 KiB release stack already holds the deepest of its own paths, so the reserve is likely smaller), **64–96 KiB** per thread. `KVirtArea` can reserve more than it maps, so a per-spawn size is a small OSTD change from today's build-time constant. 13 threads: 0.8–1.2 MiB; 21 threads: 1.3–2.0 MiB.
3. **Metadata at the template's grant.** Under C05 a clone's grant is the template's frames, so metadata scales with the template's 12–24 MiB, **0.2–0.4 MiB**; the buddy allocator writes free-list links into the slots at once, so they are private from the start.
4. **Right-sized pools and refill.** The tree's per-CPU pools hold a share of free memory, not a consumption, so for one virtual CPU the pool term is zero; `REFILL_GRAINS` of 1 (the Blueprint chose 2). The clone's written kernel pages after boot are `m_kproc`, **1–6 MiB [unverified]** (the only datum is 6 MiB of slab on a debug build under QEMU), not `m_fixed`.
5. **The worker stays**, on a small stack; the first draft's candidates row said "no worker", which the Blueprint's job delivery (D9, D11) does not allow.

## Gain

Host-side `m_fixed` from 9–13 MiB to **1.4–2.0 MiB (Python-sized) or 1.9–2.8 MiB (Node-sized)**, *estimated*; the model uses **2 MiB**. That is about a restored Firecracker VM's cost (Pss 6 MiB per restored VM measured here; Nanvix's 9.8 MiB per snapshot-restored instance includes host objects the per-process view omits, so the fair comparison is 2 MiB against 6–10 MiB, a small kernelet advantage that the model does not lean on). C04 is not a gain over the baseline; it is the correction that makes the parity claim true and that keeps the idle figures of C03 and C07 from carrying a 9–13 MiB floor. Without it the 500 ms idle figure would be 33 MiB instead of 26, which changes the memory bound but not the CPU-bound density on 128 cores.

## Evidence

- Analytic, from the Blueprint's inputs and the tree: `DEFAULT_STACK_SIZE_IN_PAGES = 128` in `ostd/src/task/kernel_stack.rs`, overridden to 8 pages for release in the tree's `Makefile`; the template sizes measured on the tree's image; the per-CPU pool balancing rule in `osdk/deps/frame-allocator/src/pools/balancing.rs`.
- Measured, for scale: a restored Firecracker VM's Pss of 6 MiB.

## Isolation

None, with fully backed stacks: a stack overflow is caught at the guard page as today and kills the kernelet. The lazily backed variant would have been a tenant-reachable machine halt, which is why it is dropped.

## Cost

A per-spawn stack size in OSTD; 4 KiB entries for `KW_DATA` and the per-switch refill; nothing on any hot path.

## Changes to the Blueprint

Recorded here, not applied: `KW_DATA` at 4 KiB private frames (Builds and images, Memory); a per-spawn `KernelStack` size, 64–96 KiB for kernelet threads, with the Tasks and Control pages' "512 KiB, measured on the tree" corrected to the tree's build settings; `REFILL_GRAINS` of 1 and pools sized to the virtual CPU count (Memory); the grant counted as tenant memory in the cost sections.
