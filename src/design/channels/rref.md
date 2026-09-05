# `RRef`, and what may be inside one

```rust
// kernelet-abi/src/rref.rs
/// A type whose values may cross a kernelet boundary: plain data, every bit pattern of which is
/// valid, with no pointer, reference, handle or `RRef` inside. Sealed and `unsafe`, so the
/// only implementations are the facade's own: `u8`..`u64`, fixed-size byte arrays, and the
/// message types the facade defines, such as `DataPacket { len: u32, bytes: [u8; 65536 - 4] }`.
pub unsafe trait Exchangeable: Pod + Send + 'static {}

/// A capability to one host-owned buffer holding a `T`. Not `Copy`, not `Clone`: the only ways
/// to give it up are to move it into `send` or to drop it. Private fields; no public constructor.
pub struct RRef<T: Exchangeable> { slot: u32, gen: u32, ptr: NonNull<T> }   // NonNull: !Sync, so no `&RRef` can alias a `DerefMut`
unsafe impl<T: Exchangeable> Send for RRef<T> {}           // in the facade (TCB); the buffer is shared-mapped
impl<T: Exchangeable> Deref for RRef<T>    { type Target = T; /* the buffer, mapped in the shared kernel half */ }
impl<T: Exchangeable> DerefMut for RRef<T> { /* ... */ }
impl<T: Exchangeable> Drop for RRef<T>     { fn drop(&mut self) { endovisor().rref_release(self.slot, self.gen) } }

pub unsafe trait EndovisorServices: sealed::Sealed {            // `endovisor()` returns the one implementation, §4.2.4
    /// A zero-filled buffer for a `T`, charged to the calling kernelet's channel account (§4.6.3).
    fn rref_new<T: Exchangeable>(&self) -> Result<RRef<T>>;
    /// Ownership transfer over a connection. On refusal the buffer comes back to the caller.
    fn send<T: Exchangeable>(&self, conn: ConnId, msg: RRef<T>) -> Result<(), (SendError, RRef<T>)>;
    /* ... */
}
```

Four properties carry the argument. **Unforgeable**: the fields are private, there is no constructor a kernelet can call, and `forbid(unsafe_code)` closes the raw pointer. **Affine**: `RRef` is neither `Copy` nor `Clone`, so after `send(rref)` the sender has no name for the buffer, and any `&T` it borrowed from the `RRef` could not outlive the move (that is the borrow checker, not a runtime check; `mem::swap` and `Option::take` move the whole `RRef`, never a part of it). **Flat contents**: `Exchangeable` is plain data, so a buffer holds bytes and never a pointer into anyone's window, and never another `RRef`, which is Alternative B's inductive rule *minus* nesting: a nested `RRef` whose row is keyed by its own owner would be released when that owner dies while the outer buffer's new owner still dereferences it. **Closed**: the trait is sealed (its private supertrait lives in the facade), so no other crate can implement it, and kernelets send the facade's message types and nothing else, which is all a byte-stream socket needs. Sealing, not the `unsafe_code` lint, is what closes it: the lint does not see `unsafe` that a macro from another crate expands to.

The `ptr` inside is a shared-kernel-half address (the buffer's frames live in host memory mapped for everyone), and dereferencing it is unchecked. That is sound because of the four properties: exactly one `RRef` names a buffer, it cannot be duplicated, its contents cannot name anything, and the host never frees a buffer while the `RRef` to it exists. Every property is compile-time except the last, which is the host table, and the last has an ordering inside it: a dying kernelet's rows are released in [destroy step 4](../faults/destroy.md) only after its in-flight entry count is zero, so no thread of the dying kernelet can still be dereferencing a buffer whose frames were reissued. The `RRef` is the one kernelet-held pointer that the windows of [§4.1.5](../process/heap-window.md) do not cover, and this paragraph is its whole argument.
