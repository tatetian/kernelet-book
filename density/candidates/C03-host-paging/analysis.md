# C03: Eviction of idle kernelets to NVMe or compressed memory

**Status:** adopted, redesigned after review; requires C02; C13 bounds its page-table growth but is not needed for its soundness. **Depends on kernelets:** no; a host can swap a VM's memory with one `madvise`, and Firecracker's own lazy snapshot restore is the same idea. Counted as a relative gain only against platforms that keep idle sandboxes warm. **Acts on:** `P_proc`, `F_written` and `m_kproc` of idle sandboxes, at the 500 ms and 5 s tiers.

## Why the first draft was unsound

The first draft evicted a kernelet's frames from the host, transparently, and paged them back on touch "as for a process's anonymous page". The review showed that under the Blueprint's physical naming (register D58) that is an isolation break: a tenant's user page tables hold the frame's machine address and are walked by the CPU, so after the frame is reused by another tenant the first tenant's process reads and writes it through ring-3 accesses that never fault. The same holds for the kernelet's page-table nodes, its `Frame` handles and its device descriptors. Restoring a page requires restoring it into the *same* frame, which saves nothing. Eviction is sound when the entries that name a machine address are cleared and their translations flushed before the frame goes, which the kernelet does cheaply through the reverse mappings it keeps for every mapped frame, followed by C02's unmap-and-flush of the window and the root-wide flush C13 lists. The guest-side swap below never needs a grain back under its old name: pages are written out by swap slot and refaulted into whatever fresh grains `grains_request` supplies. So C03 is sound under D58; what C13 adds is a bound on the window page tables under grain churn (under D58 they grow with the machine range a kernelet has ever been granted), not soundness. The first draft of this page said it required C13; the review corrected that.

## The mechanism

- **Cooperative, at grain granularity.** The endovisor's policy picks idle kernelets (no runnable task for a policy interval, no pending `timer_arm` deadline within it) and sends `JOB_SHRINK` with a target (C02). The kernelet's reclaim thread runs its reclaim to the target: it writes dirty page cache back, drops clean cache, and **swaps out anonymous pages** to a host-provided swap device (a `virtio-blk` device the endovisor backs with a per-sandbox swap file or with the compressed pool of C07), clearing its own page-table entries through its reverse mappings as it goes, then returns the emptied grains with `grains_release`. This is guest-side swap with fast grain return; it needs the reclaim subsystem C02 lists, which the kernel proper does not have today.
- **Prefetch on wake.** The kernelet records, per idle period, the set of pages the last wake touched (REAP's record, ASPLOS 2021, which cut restore latency 3.7× by fetching the recorded working set in one read). At wake the swap device is asked for the record in one sequential read before the message is delivered, and the pages are re-mapped by the kernelet's ordinary minor-fault path as the agent touches them.
- **What stays resident.** `m_fixed` (C04), the pages the policy keeps hot, and any grain a device model has pinned (`guest_memory` pins per run; a pinned run is not evictable, and an idle kernelet's posted receive buffers are the obvious case: the endovisor keeps those grains resident and the policy counts them).
- **What the kernelet-specific part is.** Not the DRAM: a VM host gets the same idle footprint by `MADV_PAGEOUT` on an idle guest's memory, blind to which pages are hot, or by suspending it to a snapshot file and restoring lazily, which Fly.io ships with resumes "in a few hundred milliseconds". The differences are in the wake: no VMM to restore, no vCPU thread, no EPT to rebuild, and page-ins that are the kernelet's own minor faults rather than EPT violations serviced across a VM exit (one to two thousand cycles each; 15,000 of them per 60 MiB is 10–20 ms per wake), and in the choice of what to evict, which the kernelet makes with its own LRU rather than the host blindly.

## Gain

Per idle sandbox at the **500 ms tier**: private DRAM from the warm figure (`m_fixed + m_kproc + F_written + P_proc`, 167 MiB in the model) to `m_fixed` plus the hot set kept resident. The hot set is a parameter: REAP measured 8–99 MB (24 MB average) working sets for restored serverless functions, so the model keeps **24 MiB** resident. A reclaim thread inside the kernelet cannot evict the kernel's own state (its slabs, task structs, page tables and socket state, `m_kproc`, 5 MiB in the model), which a host swapping a VM blindly can; so the idle figure is `2 + 5 + 24` less whatever of the hot set is itself kernel pages, **26–31 MiB**, *estimated*; the first draft's 3 MiB had no provenance and its 26 MiB omitted `m_kproc`. At the **5 s tier**, a hibernated kernelet (written out as a whole, which needs C13's host walk) holds `m_fixed` only, about 2 MiB; without C13 it holds `m_fixed + m_kproc`, about 7 MiB; and a sandbox with no written state can be destroyed and re-created from its image instead. At the **50 ms tier** NVMe is too slow for a working-set read (30 ms of a 60 MiB read at 2 GB/s before any fault), so eviction goes to the compressed pool (C07) and the miss cost, 100 µs per random NVMe read against 1–2 µs per decompression, is the argument.

Wake latency, model server, NVMe at 2 GB/s: a 24 MiB recorded read is 12 ms; 60 MiB is 31 ms; each page the record missed costs one ~90 µs random read, so a wake with 1,000 misses adds 90 ms. On this host's 185 MB/s disk the 60 MiB read alone is 340 ms, inside the 500 ms tier only with a near-perfect record.

## Evidence

- Measured: an idle restored VM adds no private pages over 25 s (`Private_Dirty` constant; this shows no *new* writes, not the absence of touches); 64 MiB cold read in 361 ms on this host.
- Published: REAP (working sets and prefetch), Firecracker's on-demand restore through `userfaultfd`, Fly.io's suspend and resume, E2B's pause and resume.
- Analytic: the DRAM per idle sandbox is `m_fixed` plus the policy's hot set.

## Isolation

None, given C02's unmap-and-flush and the root-wide flush at release that C13 lists: the kernelet writes only its own pages to its own swap device, which the endovisor backs with a per-sandbox file the kernelet cannot name; released grains go through C02's unmap-and-flush before reuse and are zeroed at the next grant (D55); a page-in returns the kernelet's own bytes. The first draft's host-transparent variant is withdrawn as unsound.

## Cost

- Per evicted page: one write, and on wake one read; with 17 wakes/s and 24 MiB per wake, 0.4 GB/s of reads and, since the evicted set is rewritten at every idle period, about the same in writes: 35 TB/day, 4–5 drive writes per day on a 7.68 TB device, which needs the compressed pool (C07) as the first tier or a swap cache that writes only dirty pages, so that clean pages are simply dropped.
- The reclaim subsystem and swap-out in the kernel proper (C02); the wake record kept by the kernelet.
- Storage: `P_proc + F_written + m_kproc` per fully idle sandbox on NVMe, 165 MiB in the model, 1.5 TiB for 9,000 idle sandboxes, plus shared images.
- CPU: the fault storm on wake, about 60 ms of minor faults per 60 MiB at the prototype's measured fault cost, 17 wakes/s is one core.

## Changes to the Blueprint

Recorded here, not applied: C02's reclaim subsystem and grain return; C13's kernelet-physical addresses for bounded page tables and for the 5 s tier's hibernation; a swap device model in the endovisor with a per-sandbox backing file or compressed pool; an idle signal on the control half (`Kernelet::idle_for()`) that accounts for `timer_arm` deadlines; the wake record; `KerneletStats` gains evicted and resident counts; the rule that pinned runs are not evictable.
