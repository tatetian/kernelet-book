# Layer 2: the facade, or how the kernel becomes a kernelet with few changes

The kernelet crate is the kernel with `ostd = { package = "kernelet-abi" }` in its manifest and about a dozen edits. `kernelet-abi` has OSTD's module tree; items that are safe to use unchanged are re-exports; items that touch global state (`IoMem`, `IrqLine`, `Task`, the allocators, interrupt control) are re-implemented over a sealed endovisor service trait; items a kernelet must not have do not exist, so a use of one is a build error.

This layer guarantees that a kernelet cannot spell an ambient authority, while the kernel's per-tenant statics and its `ostd::` paths stay untouched. It is enforced by the crate graph, a `cargo metadata` closure check, and `forbid(unsafe_code)`.

In this chapter:

- [The manifest trick](manifest-trick.md)
- [The crate graph, still the boundary](crate-graph.md)
- [Three kinds of item, and the edits they force](item-kinds.md)
- [The service trait, handles, and names](services.md)
- [What moves to the host, entry points, and kernelet kinds](split.md)
- [What the facade does not give a kernelet](denied.md)
