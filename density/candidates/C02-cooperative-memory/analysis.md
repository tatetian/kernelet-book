# C02: Host-owned frames, cooperative return

**Status:** adopted. **Depends on kernelets:** yes. **Acts on:** `m_kproc` and the churn of `m_file`; the memory a sandbox holds but no longer uses.

## The problem, measured

A VM's memory only grows from the host's point of view: a guest page once touched stays host-resident until the guest reports it free and the host discards it. Firecracker's balloon with free-page reporting does that for free blocks of 2 MiB (Linux's `page_reporting_order` is the page-block order, 9), so after the guest freed 200 MiB of page cache the host got back most but not all of it: RSS fell to **75.8 MiB against 47.2 MiB at boot**, leaving 28 MiB stranded in blocks too fragmented to report even after `compact_memory` (`../../benchmark/results/firecracker-raw.md`, `fpr3`). Reclaiming memory the guest still considers *in use* (its page cache) needs balloon inflation, a guest-side pressure event that costs guest CPU and thrashes the guest's caches, which is why production platforms keep VMs at their high-water mark instead (Squeezy, EuroSys 2026, §1: virtio-mem and ballooning "rely on costly page migrations or VM exits" and take "multiple seconds to reclaim 2 GiB").

## The mechanism

In the Blueprint every frame a kernelet has is a host-owned grain the host granted, mapped by the host into the kernelet's window, and the Memory page's assumption A1 says memory only grows because reclaiming from a running kernelet "needs its cooperation, a balloon". A kernelet, unlike a guest, is the *same source* as the host kernel and calls the host through a table; cooperation is one function:

- `grains_release(paddr, count)`: the kernelet returns whole grains it no longer uses. vOSTD calls it from the kernel proper's frame allocator when a 2 MiB-aligned run of free frames has been free for longer than a policy interval (the buddy allocator already keeps free memory in order-9 blocks; the call is made from the allocator's free path under its own lock, without sleeping). The host unmaps the grain from the window, zeroes it, clears the owner array, and puts it back in its allocator. This replaces A1's "memory only grows" with "memory grows and shrinks at grain granularity".
- Page cache in a kernelet is *granted* frames for tenant-written data and *borrowed* frames for public content (C01). The borrowed side costs the kernelet nothing to drop: unmapping a borrowed frame is a host page-cache decision. The granted side is under the kernel proper's own reclaim, as on the host kernel, and what it frees comes back through `grains_release`.
- Because the host owns the frames and the mapping, the host can also *ask*: `KerneletHooks::on_memory_pressure(k) -> target_grains`, delivered as a job (`JOB_SHRINK`) that the kernelet's kernel serves by running its reclaim to the target, the same code path Linux runs for a cgroup limit, with no page migration and no VM exit.

## Gain

Two things, both measured on the baseline: the stranded 28 MiB per VM after a reclaim becomes 0, since a kernelet returns exact grains and the host maps and unmaps at 2 MiB granularity without a guest-side reporting protocol; and the reclaim itself costs one call per grain instead of a balloon inflation cycle. On the workload model this turns `m_kproc + m_file_written` after a burst from a high-water mark into a working set: a sandbox that read 300 MiB and wrote 20 MiB holds, after its kernel's reclaim, the 20 MiB it may still need and the kernel's own state, not 320. With C01 in place the remaining private file data is small, so C02's steady-state gain is modest by itself, **10–30 MiB per sandbox**; its larger effect is that it makes C03 and C05 clean, since a paged-out or cloned kernelet never carries dead pages.

## Evidence

- Measured: free-page reporting leaves 28 MiB of a 128 MiB guest's boot-and-free memory stranded after compaction (`fpr3`); balloon inflation is the only way to reclaim in-use guest memory and is documented as CPU-intensive.
- Published: Squeezy's reclamation measurements (seconds per 2 GiB with virtio-mem; page migration dominates), and its argument that the guest OS memory manager's obliviousness to hotplugged memory is the root cause, which a kernelet does not have: its allocator and the host's are the same code over the same frames.
- Analytic: a grain returned is 2 MiB of host memory reusable at once; the cost is one call and one 2 MiB zeroing.

## Isolation

None: a released grain is zeroed before reuse (register D55), as at destroy; a kernelet can only release what it owns, checked against the owner array; the pressure job is a request the kernelet may ignore, at the price of being a candidate for C03's eviction first.

## Cost

- One service call and one 2 MiB zeroing per released grain; the kernel proper's allocator must keep a free-for-long timer per order-9 block (a few lines in the frame allocator's free path).
- A shrink job costs the kernelet's own reclaim CPU, as a cgroup limit does on Linux.

## Changes to the Blueprint

Recorded here, not applied: assumption A1 withdrawn in favor of grain-granular shrink; one service function `grains_release`; one hook `on_memory_pressure` and one job kind `JOB_SHRINK`; the Memory page's grant table becomes a table with holes, and the owner array's clear-on-release is what already exists for destroy.
