# Layer 5: devices, or virtio without the traps

Virtio front-end drivers stay in the kernelet; the host implements virtio backends whose register file is a Rust struct and whose descriptors are checked against the owner array; passthrough hands a real device to one kernelet under the IOMMU.

This layer guarantees that a kernelet's I/O touches only its own frames, and that the host's device surface has a specification. It is enforced by the owner check per descriptor and by the IOMMU.

In this chapter:

- [Why virtio, and why over function calls](why-virtio.md)
- [The backend](backend.md)
- [What the backend costs and what it does not solve](cost.md)
- [Passthrough](passthrough.md)
