# The service trait, handles, and names

Behind every virtualized item is one sealed trait, `EndovisorServices`, whose only implementation is a wrapper that opens a **host scope** (sets the attribution words of [§4.3.1](../memory/arena.md) so that nothing the host allocates lands in a tenant's arena), performs the stack check of [§4.4.5](../threads/stack-check.md), checks whether the calling kernelet is dying, and delegates. Its methods take either a **handle** or a **kernelet-relative name**, and never a pointer into a kernelet's memory.

A **handle**, `Handle<T>`, is a typed index into the calling kernelet's own handle table plus a generation, with private fields and no public constructor. Every use goes through the **resolver**, about thirty lines that check, in order: (1) the kernelet's **epoch**, a per-kernelet counter the host bumps once to revoke every handle the kernelet holds, which is how a kill takes effect on every CPU with one store; (2) bounds; (3) presence; (4) generation, against use-after-close; (5) kind, against type confusion; (6) owner, redundantly; (7) rights. One relaxed load, no write, about 16 cycles in a user-space model. A **kernelet-relative name** (`ThreadRef`, `JobId`, `IoToken`) is a plain integer that means something only to the kernelet that minted it and only while that kernelet's `KerneletId` is live; the sealed bound `KerneletRelative: Copy + 'static` is the only type a host table may store about a kernelet, so that the host cannot retain a borrow (the borrow checker) or a pointer (the bound), and now, in thread context, could not use one if it did ([§4.1.5](../process/heap-window.md)). The exceptions, the **declared holders**, are enumerated in [§4.3.1](../memory/arena.md) and retired one by one in [§4.7.4](../faults/destroy.md).

The handle kinds are six. Alternative A had ten; `MemArena`, `CpuBudget`, `Timer` and `KerneletCtl` survive as they were, `VirtioDev` absorbs `BlockRange`, `NetFlow`, `FsTransport`, `Console`, `Entropy` and `Channel`, and `Passthrough` is new:

| kind | what it is |
|---|---|
| `MemArena` | the grant of frames the kernelet's arena and user memory come from, in 2 MiB grains |
| `CpuBudget` | the kernelet's scheduling group: weight, quota, affinity, and the bounds within which it may reorder its own threads |
| `Timer` | the right to arm wakeups and jobs on the host timer wheel |
| `VirtioDev` | one virtio device of a given device type (block, net, console, rng, fs, vsock), backed by a host backend ([§4.5](../devices/index.md)) |
| `Passthrough` | one physical device's registers, DMA capability and interrupt, under the IOMMU ([§4.5.4](../devices/passthrough.md)) |
| `KerneletCtl` | control over a kernelet; held by the host, never granted laterally |

Inter-kernelet communication needs no kind of its own: it is a `VirtioDev` of type vsock whose backend is the message table of [§4.6](../channels/index.md).
