# C05: Templates

**Status:** adopted in the process-level form; the kernel-level clone is recorded as the variant that needs C13 and a quiesce protocol. **Depends on kernelets:** no; a VM snapshot restore does the same. **Acts on:** the runtime's initialized heap, and, in the kernel-level variant, the kernel's boot residue.

## Why the first draft was infeasible

The first draft cloned a *running* kernelet copy-on-write: the template's frames mapped read-only into the clone, copied on the first write. The review found it undefined under the Blueprint's physical naming and, as written, an isolation breach: a clone's user page tables would be the template's, naming the template's frames by machine address and walked by the CPU, so the clone's first user-mode store would write shared memory that every other clone reads. Nor can a running kernelet's threads be cloned: they are host threads parked at service depth one with host frames on host stacks, and the Blueprint has no freeze state, no quiesce protocol and no resume entry. And the kernel's random-number generator is a single seeded state in the kernel heap (`kernel/core/src/util/random.rs`), so clones would share every `getrandom` output, every ASLR offset and every `AT_RANDOM` value; the vsock CID is read once at driver initialization; timers are keyed on host jiffies; and the agent's control connection would be reset in every clone.

## The feasible form: a process-level template

The runtime process, not the kernel, is what is expensive to initialize and identical across sandboxes. So:

- Each sandbox boots a **fresh, lean kernelet** (C04): fresh kernel, fresh RNG, fresh CID, no template frames to reference-count. The kernel's boot residue is paid per sandbox: single-digit MiB *estimated* (the only datum is 6 MiB of slab for a debug build under QEMU), to be measured, and it is the `m_kproc` the model carries.
- The agent runtime is pre-initialized once per image into a **checkpoint file** placed in the shared image: the process's memory image after loading its modules and reaching the point where it waits for its first message, with no tenant data and no open sockets (the environment, secrets and the control connection are applied *after* restore, which is also what makes the template tenant-neutral). Node's startup snapshot, Python's `fork`-server pattern, or a CRIU-style user-space restorer are the tools; which kernel interfaces the tree lacks for a general restorer is **[unverified]**.
- The restorer maps the checkpoint `MAP_PRIVATE` over the image's borrowed frames (C01), so the **tenant kernel** does the copy-on-write in its own page tables with its own reverse mappings, which is the one place it is correct. Private memory equals written pages, exactly the property the first draft claimed for the kernel-level clone.

## The kernel-level variant, recorded

With C13's kernelet-physical addresses a kernel-level clone becomes definable: a quiesce protocol in the kernel proper (`JOB_QUIESCE`: user threads at the top of the `execute` loop with the interrupted system call marked for restart, kernel threads at the tops of their loops, each recording a resume descriptor and exiting its host thread; a `Frozen` state off the tick list with `raise_irq` refused); a clone spawns one host thread per descriptor through `spawn_task` with the same task index and generation; the clone's page-table frames are copied and their entries translated through the clone's p2m at clone time (bounded: a template with a hundred page-table pages is sub-millisecond); user-mapped frames are copied eagerly, so the runtime's anonymous pages (`P_proc`) are private from the start and only the kernel-private remainder stays shared; a clone generation counter in the info page makes the kernel reseed its RNG from `rdrand`, re-arm its timers and reload its CID after the switch delivers `TransportReset`; the agent reconnects; the device table must equal the template's with only backing descriptors substituted. Gain over the process-level form: the kernel's boot residue shared instead of paid, single-digit MiB per sandbox. Cost: the protocol above and the `TransportReset` handling, on top of C13. Deferred until the boot residue is measured and found to matter.

## Gain

The baseline gets the same sharing from a snapshot restore: two VMs restored from one snapshot held 0.86 MiB private each (`../../benchmark/results/firecracker-raw.md`), and a restore took 11–36 ms of wall time. The process-level template gives a kernelet the same `P_proc` sharing until written, at a mechanism cost of a kernelet boot (to be measured; the Paper's Evaluation chapter will measure it against a microVM boot) plus a process restore. It is not a density gain over the baseline and the model does not count it as one; it is what keeps `P_proc` from being paid twice per sandbox at creation.

## Evidence

- Measured: snapshot-restored VMs share all but 0.86 MiB; Firecracker restore 11–36 ms wall time.
- Published: REAP's working-set figures; Firecracker's documented `MAP_PRIVATE` restore; "Restoring Uniqueness in MicroVM Snapshots" (arXiv 2102.12892) for the RNG and identifier hazards, which the process-level form avoids by construction.

## Isolation

The process-level template is public content of one image, restored under the tenant kernel's own copy-on-write; the residual is C01's (Flush+Reload on shared read-only pages, container grade). A pre-initialized *heap* shared read-only is a larger surface than library text, and it counts as public only because it is deterministic from the image and a tenant-neutral configuration; the platform's `share_image` opt-out covers it.

## Cost

A checkpoint file per (image, runtime configuration); the restorer; the kernelet boot per sandbox, against a VM restore.

## Changes to the Blueprint

Recorded here, not applied: nothing in vOSTD for the process-level form; the runtime page's `create` gains "restore the runtime from the image's checkpoint, then apply the environment"; the kernel-level variant's list above, contingent on C13.
