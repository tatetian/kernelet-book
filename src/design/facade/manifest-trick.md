# The manifest trick

Alternative A's first idea, that a kernelet's kernel is a crate with no dependency edge to OSTD or the host, is kept exactly. Its facade crate, `kernelet-abi`, re-exported a vetted subset of OSTD under new paths, and the kernel's 685 `ostd::` references were rewritten to match. Alternative B's observation is that the rewrite is unnecessary: a guest is an unmodified framekernel service, and what changes is the *implementation* of the API it was written against.

Cargo can express that in one line. `aster-kernelet` is the kernel crate with this dependency:

```toml
# kernel/core/Cargo.toml when built as a kernelet
[dependencies]
ostd = { package = "kernelet-abi", path = "../../kernelet-abi" }
```

The source says `ostd::mm::VmSpace` and `ostd::sync::SpinLock`; the name `ostd` resolves to `kernelet-abi`, whose module tree mirrors OSTD's. The same source with `ostd = { path = "../../ostd" }` is the kernel as it is today. **No path rewrites, and one source tree that builds both ways.** An item the facade does not define fails to resolve, so the list of what a kernelet may use is the facade's public surface, and a kernelet reaching past it is `error[E0433]`. One caveat with macros: a `macro_rules!` re-exported from OSTD expands `$crate` to the real `ostd`, bypassing the facade, so the facade defines its own `log` family, `const_assert!`, `early_println!` and `if_tdx_enabled!` (the six macros the kernel uses) rather than re-exporting OSTD's.

"Builds both ways" is true of the *shape* of the source and not of every line. [§4.2.3](item-kinds.md) lists what does change, and [§6.1](../../evaluation/bill.md) counts it.
