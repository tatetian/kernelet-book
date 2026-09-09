# C03: Transparent host paging of idle kernelets

**Status:** adopted. **Depends on kernelets:** no; KVM guests' memory can be swapped by the host too. **Acts on:** `P_proc` and `m_kproc` of idle sandboxes, at the 500 ms and 5 s tiers.

## The problem

Ninety percent of sandboxes are idle at any instant, and each idle one holds its runtime's heap and its kernel's state in DRAM: 60–70 MiB in the workload model after C01 and C02 have removed the file copies. Ten thousand of them is 650 GiB, most of the server, holding pages nobody will touch for minutes. The wake tiers say how long a sandbox may take to get them back.

## The mechanism

A kernelet's frames are host-owned and mapped into its window by the host, so the host can unmap one, write it out, and map it back on the next touch, exactly as it does for a process's anonymous page, and the kernelet need not know:

- **Eviction.** The host picks idle kernelets (no runnable task for longer than a policy interval, the same signal the reaper and the idle-tick logic already have), and for each evicts its granted frames to a compressed pool in DRAM (C07) or to an NVMe swap area: unmap the 2 MiB entry in the window, split it into 4 KiB entries where a partial grain is worth keeping, write the pages out, mark the entries not-present with the swap slot in the entry, keep the grain's owner-array entry.
- **Refault.** A kernelet task that touches an evicted page takes a page fault in kernelet text at a window address. The Blueprint's fault handler today kills the kernelet for any kernel-half fault without an exception-table entry (User mode page, register D22); the change is one case before that rule: *if the address is in `KW_PHYS` and the entry is a swap entry, page it in and resume*. The task is at service-call depth zero in kernelet code, so the handler may sleep for the read (it becomes, in effect, a service call the hardware made), and its preemption count is honored as everywhere else. A host task touching the same frame through `guest_memory` (a device model) takes the same fault on the linear map and the same page-in.
- **Wake.** A message for an idle sandbox is a virtual interrupt; the worker's job delivery touches the kernelet's data and the receiving thread's stack and heap, which fault in the working set page by page. To meet a tier without paying one NVMe round trip per page, the host **prefetches the record**: at eviction it notes which pages the last wake touched (REAP's record-and-prefetch, ASPLOS 2021, which cut restore latency 3.7× by fetching the recorded working set in one read); at wake it reads that set in one sequential read before delivering the job.

A KVM guest can be swapped by the host in the same way, and with the same prefetch trick, and platforms that pause idle VMs to a snapshot file (E2B, Fly.io) are doing the coarse version. The kernelet's advantage is in what does *not* need restoring: no VMM process, no vCPU thread, no EPT to rebuild, no guest kernel to bring back before the first useful instruction, and page-ins that are host page faults on the kernelet's own thread rather than EPT violations serviced across a VM exit. It also composes with C01 and C05: shared and borrowed pages are never evicted, because they are never private.

## Gain

Per idle sandbox at the **500 ms tier**: private DRAM from ~67 MiB (after C01, C02) to `m_fixed` plus the pages the host chooses to keep hot, taken as **3 MiB** (the record of the last wake's first touches, so that the first response needs no disk read at all). At the **5 s tier**: the same, since the tier is far above what the mechanism needs. At the **50 ms tier**: NVMe is too slow for a full working-set read (60 MiB at 2 GB/s is 30 ms of the budget, before the fault storm), so idle memory goes to the compressed pool of C07 instead.

Wake latency, model server, default working set 60 MiB, NVMe at 2 GB/s: one sequential read of the recorded set, 30 ms, plus the faults for what the record missed. On this host's slow disk the same read measured 185 MB/s, 360 ms, still inside the 500 ms tier. REAP measured 8–99 MB (24 MB average) working sets for restored serverless functions, so 60 MiB is conservative for an agent.

## Evidence

- Measured: an idle restored VM holds 0.86 MiB private and touches nothing for 25 s (`../../benchmark/results/firecracker-raw.md`), so idle sandboxes really are idle; 64 MiB cold read in 361 ms on this host's disk.
- Published: REAP (working sets and prefetch), Firecracker's own on-demand restore through `userfaultfd`, Fly.io and E2B pausing idle microVMs.
- Analytic: the DRAM per idle sandbox is whatever the policy keeps hot, bounded below by `m_fixed`.

## Isolation

None. Frames stay host-owned and stay charged to the kernelet; the swap area is host storage the kernelet cannot name; a page-in returns the kernelet's own bytes; the slot is zeroed when the kernelet is destroyed, as the frame is. The one new host path, a sleeping page-in inside the fault handler for a kernelet task, runs at depth zero on the kernelet's own thread and is terminable at its return, as every other kernelet fault is.

## Cost

- Per evicted page: one write and, on wake, one read; NVMe bandwidth for the fleet's wake rate: 17 wakes/s × 60 MiB = 1 GB/s of reads, a third of one NVMe device.
- Per evicted kernelet: the record (a bitmap, 1 bit per page of its grant) and the split of 2 MiB entries into 4 KiB entries for partially hot grains: 4 KiB of page tables per 2 MiB grain.
- The host fault handler gains a sleeping path for kernelet tasks; the Blueprint's "kernel-mode fault in kernelet code kills the kernelet" rule gains one exception, checked first.
- Storage: `P_proc + m_kproc` per idle sandbox on NVMe, 700 GB for 10,000, plus their root images, which are shared.

## Changes to the Blueprint

Recorded here, not applied: the fault handler's swap-entry case; an eviction policy in the endovisor over an idle signal the control half exposes (`Kernelet::idle_for()`); the wake record kept beside the grant table; `KerneletStats` gains evicted and resident counts.
