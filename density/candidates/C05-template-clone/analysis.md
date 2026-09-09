# C05: Template cloning

**Status:** adopted. **Depends on kernelets:** no; VM snapshot restore with a shared memory file does the same for guests. **Acts on:** `m_boot` and the initial `P_proc`: the memory a sandbox holds after boot and runtime initialization, before any tenant work.

## The problem, measured

A cold-booted 128 MiB Firecracker guest touches **33.4 MiB** by the time `init` runs and holds 45 MiB of host RSS; with a Python runtime loaded, 60 MiB touched, 71 MiB RSS (`../../benchmark/results/firecracker-raw.md`). Every sandbox booting from scratch pays that privately. Restoring from one snapshot instead makes it shared: two VMs restored from the Python snapshot held **0.86 MiB private each** and 9 MiB of shared page cache, and stayed there while idle. The pages become private only as the guest writes them, which a guest kernel does steadily (slab churn, page-table updates, the runtime's garbage collector), so the shared fraction decays over the sandbox's life; REAP measured that a restored function's working set is 8–99 MB against 100–200 MB booted.

## The mechanism

The endovisor keeps, per image and per agent configuration, one **template kernelet**: booted, its agent runtime loaded and initialized to the point where it waits for its first message, then frozen. A new sandbox is a **clone** of the template rather than a fresh kernelet:

- The clone gets a fresh `Kernelet` object, slot, identity, page tables and shared pages, and its grant is the template's frames mapped **read-only** into its window, with the owner array marking them **template** frames; the clone's `KW_DATA` and metadata frames are the template's too, read-only.
- A write by the clone to a template frame takes the host fault path C03 and C04 add: copy the 4 KiB page into a fresh granted frame (charged to the clone), map it read-write, resume. A clone that never writes a page never owns it.
- The kernel proper needs to re-randomize what a clone must not share: the kernel's entropy pool, its boot-time identifiers, the agent's session secrets; that is the "restoring uniqueness in microVM snapshots" problem (arXiv 2102.12892) and its answer is the same, a post-clone hook the agent runs first.
- The template is never scheduled; its frames are host page cache in effect, one copy per image on the server.

A VM snapshot restored with a `MAP_PRIVATE` mapping of the memory file is the same idea and is what the baseline measurement above did. The kernelet's version has no VMM to restore (35 ms measured per VM restore), no vCPU thread to create, no EPT to rebuild, and no guest kernel to re-enter its idle loop; a clone is a control-half `create` from an existing frame set plus one thread start, and its first instruction is the agent's.

## Gain

Per sandbox: `m_boot` (33–60 MiB cold) → **0**; the runtime's initialized heap `P_proc` starts shared and becomes private at the rate the runtime writes it, so a freshly cloned idle sandbox costs `m_fixed` alone, **~1.5 MiB with C04**, and one that has served a burst costs its written pages, taken as the full `P_proc` of 60 MiB in the model to stay conservative. The gain over the baseline is therefore not in the number but in the mechanism's cost: the baseline gets the same sharing by restoring from a snapshot at 35 ms per restore and 4 threads per VM. The clone's other effect is on C03 and the 5 s tier: a sandbox that has been idle long enough to be evicted entirely can be **discarded and re-cloned** if its private state is small, which costs no NVMe write or read at all.

## Evidence

- Measured: two VMs restored from one snapshot share all but 0.86 MiB; Firecracker restore 18–36 ms.
- Published: REAP working-set figures; Firecracker's documented `MAP_PRIVATE` restore and page sharing between clones; Nanvix's 104 Firecracker instances per GiB from snapshots against 20 cold-booted.
- Analytic: private memory of a clone equals its written pages.

## Isolation

Within the floor: the template holds one image's public state and no tenant data; clones are read-only over it and copy on write; the uniqueness hook re-keys entropy and identifiers, without which two clones would share a random-number state, which the literature above treats as the one real hazard of snapshot cloning. Template frames are never granted writable and are freed only when no clone references them.

## Cost

- The host fault path for copy-on-write, one 4 KiB copy per first write; page-table entries at 4 KiB granularity for template frames (the 2 MiB grain mapping is split lazily, as in C03).
- One template kernelet per (image, agent configuration) per server, tens of MiB each.
- Reference counting of template frames in the owner array (a count per frame, 4 bytes, in the template's metadata).

## Changes to the Blueprint

Recorded here, not applied: a `template` owner state with a reference count; `Kernelet::clone(template, config)` on the control half; the copy-on-write fault path; a `KERNELET_CLONE` ioctl and the runtime's use of it in place of `CREATE` + boot for the common case; the uniqueness hook in the agent.
