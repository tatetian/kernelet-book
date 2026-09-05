# Layer 6: talking between kernelets, or ownership that moves

Between kernelets, `AF_VSOCK` over `RRef<T>` messages: host-owned buffers of plain data whose ownership moves by a table update, with receiver-posted credit.

This layer guarantees that a message never carries a pointer, and that a dead kernelet's messages are reclaimed. It is enforced by the `Exchangeable` bound, implemented only by the facade, and by the RRef table.

In this chapter:

- [The problem and the two answers](problem.md)
- [`RRef`, and what may be inside one](rref.md)
- [The table, the transfer, and the accounting](table.md)
- [Vsock, and what a tenant sees](vsock.md)
- [When a kernelet dies mid-conversation](death.md)
