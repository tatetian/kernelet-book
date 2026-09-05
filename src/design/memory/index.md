# Layer 3: memory

Most of this layer is Alternative A's, and it is summarized rather than re-derived; what the windows change is called out.

From Alternative A, mostly as it stands: a per-kernelet arena behind the allocator hooks, ownership as accounting, `ENOMEM` on the compatibility surface and a death reserve behind the infallible one.

This layer guarantees that the kernelet that runs out is the kernelet that overspent, and that nothing charged to a kernelet returns null. It is enforced by the allocator hooks and the owner array.

In this chapter:

- [The arena, and who is running](arena.md)
- [Frames and the owner tag](frames.md)
- [Two bands, and the death reserve](bands.md)
- [Address spaces](address-spaces.md)
- [Per-CPU caches and the floor](per-cpu.md)
