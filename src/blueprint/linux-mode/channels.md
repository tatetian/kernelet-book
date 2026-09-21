# Channels

*How a kernelet talks to the host and to other kernelets, given that it shares no memory with anyone. It discharges the ownership rule for data that moves between sandboxes.*

## A socket family the tenant already has

A kernelet has no shared memory with the host or with its neighbors, and the design does not add any. It communicates the way a guest in a virtual machine does: over **vsock**, a socket family (`AF_VSOCK`) made for talking across a virtualization boundary, in which an endpoint is named by a **context identifier** (CID) and a port instead of an IP address and a port.

The kernel proper already has a vsock socket layer and a virtio-vsock driver, and both are unchanged. The runtime attaches one virtio-vsock device to a sandbox; a sandbox without one has no channel except its console. Behind the device, in the endovisor, is the **vsock switch**.

One mechanism therefore serves three purposes: the runtime's control connection to the agent inside the sandbox ([Kernelet runtime](kernelet-runtime.md)), any stream the tenant wants to the host, and traffic between sandboxes where the operator's policy allows it.

## Addresses

Each sandbox gets a CID when it is created, from a counter that never reuses a value while the machine is up, so an address a peer has cached can never reach a successor. CID 2 is the host, as the vsock specification says; 0 and 1 are reserved.

## The switch

The switch is a table of connections keyed by the two CIDs and two ports. It does three things.

**It routes, and it does not believe headers.** A packet is taken from a sandbox's transmit ring by that sandbox's [device thread](virtualizing-ostd/devices.md). The packet's header was written by the tenant's kernel, so the switch overwrites the source CID with the sender's real one before looking at anything else; a sandbox cannot speak as another or as the host. It then delivers by destination: to the host endpoint for CID 2, to another sandbox's receive ring if that sandbox is alive and the policy allows the pair, and with a reset otherwise.

**It copies, and it enforces credit.** vsock has flow control built in: each side advertises how many bytes it can buffer, and a sender must not exceed it. The sender's device thread copies a packet's payload out of the sender's buffer, after the usual [grant check](virtualizing-ostd/memory.md), into a queue entry in endovisor memory that is charged to the sender's control group. The receiver's device thread copies it into a buffer from the receiver's ring, again after the grant check. There are two copies and no moment at which one sandbox's frame is visible to another. Bytes in flight per connection are bounded by the switch's own limit, 256 KiB (*chosen*, equal to what the kernel proper's socket layer advertises): the credit a receiver advertises is written by a tenant's kernel, so the switch clamps it to that limit in both directions and never believes a larger number. Connections per sandbox are bounded by policy (256 by default, *chosen*), so a sandbox cannot make the endovisor hold unbounded memory on its behalf.

**It forgets.** When a sandbox is marked dying, the switch resets all of its connections, frees their queues and marks its CID dead. [Destroy](faults-and-reclamation.md#destroy) later checks that none is left.

## The host's end

On the host side, a connection is a stream file descriptor that the runtime obtains from the sandbox descriptor with `KERNELET_CONNECT` (to reach a port a tenant process listens on) or `KERNELET_LISTEN` (to accept connections from inside). It is an ordinary descriptor: it can be read, written, polled and passed to another process.

Linux has its own `AF_VSOCK` family for its virtual machines, and the endovisor could register itself as a transport for it, so that host programs would reach a sandbox with plain sockets. It does not, in this design, because Linux allows one host-to-guest transport at a time and an operator who also runs virtual machines with vhost-vsock needs that slot. **[unverified]**: whether the two can coexist has not been examined.

## Costs

Per packet: two copies of at most 4 KiB, two device-thread wakeups when the threads were idle, one virtual interrupt. *Measured here* (the development machine, in user space): a 4 KiB copy costs 33 ns hot and 457 ns cold, and a thread wakeup about 3 µs, so for small messages the wakeups dominate and the copies are noise. Bulk transfer between sandboxes is the case [zero-copy I/O](zero-copy-io.md) addresses.

## What a tenant sees

`AF_VSOCK` stream sockets, with the host at CID 2. A connection to a sandbox that has died is reset.

## What this page decides

- **Channels are vsock through a switch in the endovisor, with copies on both sides** (register D37 and D38, kept). Shared memory between sandboxes was rejected: it would be the first memory in the design that two tenants can both write.
- **Reachability between sandboxes is denied by default** (register D68, kept); a runtime that holds both sandbox descriptors opens a pair.
- **The host's end is a descriptor from the endovisor's device, not Linux's `AF_VSOCK`** (register D39, kept, for a reason specific to Linux: the one host-to-guest transport slot).
