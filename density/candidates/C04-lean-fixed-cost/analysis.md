# C04: A lean fixed cost per kernelet

**Status:** adopted; needs changes to the Blueprint. **Depends on kernelets:** yes. **Acts on:** `m_fixed`, the memory a sandbox costs before it does anything.

## The problem: the Blueprint as written is not lean

The Design chapter was written for correctness and simplicity, not density, and its fixed cost per kernelet is higher than a snapshot-restored Firecracker VM's 1.5 MiB. Counted from the Blueprint's own pages, for a one-vCPU sandbox whose agent runtime has 10 threads:

| item | Blueprint today | per sandbox |
|---|---|---|
| `KW_DATA`: the writable data template, padded to one 2 MiB page (Builds and images) | 2 MiB private copy | 2.0 MiB |
| per-virtual-CPU `.cpu_local` replicas | 2 KiB each | ~0 |
| kernel stacks: every kernelet task is a host thread with a fully backed 512 KiB stack (Tasks) | 512 KiB × (10 threads + 1 worker + boot) | 6.0 MiB |
| frame metadata: 8 host frames per granted grain (Memory) | 32 KiB per 2 MiB, 1.56 % | 1.6 MiB at 100 MiB granted |
| window page tables: level-2 per GiB touched, level-1 per 128 MiB of metadata | a few frames | 0.1 MiB |
| the initial grant's floor: the kernel proper's slabs and the buddy allocator's per-CPU pools (Memory, *estimated* 8 grains + 4 per vCPU) | 24 MiB granted before a process runs | 24 MiB |
| task records, shared pages, `Kernelet` object, device inbox | tens of KiB | 0.1 MiB |
| **total** | | **~34 MiB** |

At 10,000 sandboxes that is 340 GiB before any tenant work: more than a third of the server.

## The mechanism: four changes

1. **Copy-on-write data template.** Map `KW_DATA` from the kind's template frames read-only, at 4 KiB granularity, and let the host's fault handler copy a page into a private frame on the first write (the same swap-entry path C03 adds, with "template" as the entry kind). The Blueprint's measured host image writes `.data` 27 KiB, `.bss` 24 KiB and `.cpu_local` 2 KiB; the pages a kernelet actually writes at boot are a few dozen. From 2 MiB to **~0.2 MiB**. The price is the loss of the single 2 MiB TLB entry for data, which register A2 wanted for translation refill; a kernelet's hot data pages number in the tens, so the refill is tens of 4 KiB walks.
2. **Small, demand-backed kernel stacks.** OSTD sizes every stack by one build-time constant, 128 pages fully mapped (`ostd/src/task/kernel_stack.rs`). Kernelet threads get a `KernelStack` variant with a 64 KiB reservation, backed on demand by the guard-page fault path the host already takes for a stack overflow (register A6's double-fault handler becomes a page-fault handler for the reserved but unbacked range, at depth zero). A thread that only ever runs a system call or two touches 8–16 KiB. Stack reserve for host code (A3, 64 KiB) is unchanged since service calls run on the same stack: the reservation is 64 KiB for the kernelet's use *plus* the reserve, 128 KiB virtual, ~16 KiB resident. From 6 MiB to **~0.2 MiB** for 12 threads.
3. **Right-sized initial grant.** The buddy allocator's per-CPU pools and the slab caches are sized for a host kernel with many CPUs; a one-vCPU kernelet needs one pool, and `REFILL_GRAINS` of 1. With C05 the template kernelet has already paid the slab initialization and its pages are shared until written. From 24 MiB granted to **4 MiB granted, ~1 MiB private** after cloning.
4. **Metadata and worker.** Keep the 1.56 % metadata (it is proportional and small once the grant is small: 64 KiB at 4 MiB). The one worker per virtual CPU stays but on a small stack (item 2); its thread is idle and costs nothing but its stack.

## Gain

`m_fixed` from ~34 MiB to **~1.5 MiB** for a one-vCPU, 10-thread sandbox: 0.2 (data) + 0.2 (stacks) + 1.0 (grant floor written pages) + 0.1 (metadata and tables). That is on par with a restored Firecracker VM's 1.5 MiB, and it is the floor that C03's eviction leaves in DRAM; without it, C03's idle figure of 3 MiB per sandbox would be 36 MiB and the whole scheme would miss its target. So C04 is not a gain over the baseline; it is the correction that makes the other gains real.

## Evidence

- Analytic, from the Blueprint's own measured inputs: the tree's 512 KiB stacks (`DEFAULT_STACK_SIZE_IN_PAGES = 128`), the template sizes measured on the tree's image, the Memory page's floor estimate.
- Measured on Linux for scale: a Linux thread's kernel stack is 16 KiB and its `task_struct` about 10 KiB, and Linux's own `vmap`ed stacks are backed lazily; nothing in a kernel thread's needs requires 512 KiB resident.

## Isolation

None. Demand-backed stacks change where a stack overflow is detected (a fault in the unbacked range rather than the guard page), not what happens: the kernelet is killed. Copy-on-write template pages are private after the first write and never shared once written.

## Cost

- Host fault-handler paths for template and stack pages, at depth zero on the kernelet's thread; a 4 KiB page-table entry per data page instead of one 2 MiB entry.
- Stack growth by page faults costs a fault per new 4 KiB of stack, once per thread lifetime.

## Changes to the Blueprint

Recorded here, not applied: `KW_DATA` at 4 KiB pages, template mapped read-only, copy on first write (Builds and images, Memory); a lazily backed `KernelStack` for kernelet threads with a 64 KiB reservation, and A6's handler reading the reservation (Tasks, Faults); `initial_grains` default and `REFILL_GRAINS` of 1 with pools sized to the virtual CPU count (Memory); D16's `preempt_switch` unaffected.
