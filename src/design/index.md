# Design

This chapter is the specification. It builds the design one layer at a time, in the order a reader needs them: where a kernelet's bytes live, how the kernel becomes a kernelet with few changes, memory, threads and scheduling, devices, communication between kernelets, and faults and reclamation. Three paths walked end to end close the chapter. Each layer's index page says what it guarantees and what enforces it; the layer table in [Architecture](../architecture/layers.md) is the summary.

In this chapter:

- [Layer 1: the process, or where a kernelet's bytes live](process/index.md)
- [Layer 2: the facade, or how the kernel becomes a kernelet with few changes](facade/index.md)
- [Layer 3: memory](memory/index.md)
- [Layer 4: threads and scheduling](threads/index.md)
- [Layer 5: devices, or virtio without the traps](devices/index.md)
- [Layer 6: talking between kernelets, or ownership that moves](channels/index.md)
- [Layer 7: faults, forced termination, and reclamation](faults/index.md)
- [Three paths, end to end](walkthroughs.md)
