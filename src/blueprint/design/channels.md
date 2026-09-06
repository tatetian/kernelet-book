# Channels

*Cuts across the resources. Specifies how a kernelet talks to the host and to other kernelets: the vsock device model, its host-side switch, and the copy path. Discharges invariant I2 for the memory that moves between kernelets and I4 for what the host remembers about a connection.*

A kernelet has no shared memory with anyone. It talks to the host and to other kernelets the way a microVM guest does: over `AF_VSOCK`, with the kernel proper's own virtio-vsock driver (checked on the tree: `kernel/core/comps/virtio/src/device/socket`, 865 lines), on a virtual device whose model in the endovisor is a **vsock switch**. What a tenant gets is a socket family it already uses, with the host at CID 2 and each kernelet at a CID of its own; what the design gets is one mechanism for the runtime's control connection, for console and log streams that want a socket rather than a device, and for kernelet-to-kernelet traffic, all of it through the same owner-checked device path as every other device.

## The device

The endovisor attaches one `virtio-vsock` device to every kernelet by default, with a CID it assigns from a host-wide space above 2 and the standard three queues, receive, transmit and event (checked on the tree: the driver registers callbacks on all three). The kernelet's driver is unchanged. The device model is the one [Devices](virtualizing-ostd/devices.md) describes, with the vsock packet format of the specification: a header of source and destination CID and port, length, type, operation, flags, and the two credit fields, followed by the payload; the driver's `VirtioVsockHdr` and its operations `Request`, `Response`, `Rst`, `Shutdown`, `Rw`, `CreditUpdate` and `CreditRequest` are exactly those (checked on the tree: `device/socket/header.rs`).

## The switch

Behind the model sits the switch, one per host, in the endovisor. It holds a table of **connections**, each keyed by the four-tuple of CIDs and ports and holding: the two endpoints, each a kernelet's CID or the host; the per-direction credit, the `buf_alloc` and `fwd_cnt` the peers advertised; and a bounded queue of payload bytes in flight, in host memory, charged to the sending kernelet with `charge_host_bytes`. The switch does three things:

- **Routes.** A packet a kernelet transmits, taken from its transmit queue by the device thread, is delivered by destination CID: to the host endpoint if the CID is 2, to another kernelet's receive queue if the CID is a live kernelet's, and answered with `Rst` otherwise. Connection setup (`Request`, `Response`), teardown (`Shutdown`, `Rst`) and credit are handled per the specification, by the switch, so that a peer cannot exceed the credit the other advertised.
- **Copies.** The payload of an `Rw` packet is copied out of the sender's transmit buffer into a host queue entry, and later from that entry into the receiver's receive buffer, each copy under `guest_memory` on the respective kernelet with the grains pinned; two copies per packet between kernelets, one per packet between a kernelet and the host. The host-side queue is bounded per connection by the credit the receiver advertised, which the switch caps at a policy value (64 KiB by default, chosen), so that a fast sender cannot make the host hold unbounded bytes for a slow receiver.
- **Resets.** When a kernelet dies, every connection with it as an endpoint is torn down: the peer receives `Rst`, the queued bytes are freed and uncharged, and the table entries are removed; this is one of the drain steps of [Faults, termination, and reclamation](faults-and-reclamation.md), performed by the endovisor in `on_dying` since the switch is its table.

The host endpoint is what the kernelet runtime and other host programs see: a connection to CID 2 on a port the runtime listens on, or from the host to a kernelet's CID and port, surfaces in host user space as a stream file descriptor obtained through the [endovisor ABI](endovisor.md). The host kernel has no `AF_VSOCK` socket family of its own today (checked on the tree: nothing under `kernel/core/src/net` defines one), so the endovisor does not add one; it hands out stream descriptors backed by the switch, which is what the runtime needs and no more.

## What crosses, and what the host remembers

Nothing but bytes crosses between kernelets: no frame changes owner, no pointer is carried, and the driver on each side sees a device that delivered or accepted a packet. The switch's table holds CIDs, ports, credits and byte queues, never a window address or a task name, so a kernelet's death leaves nothing dangling (invariant I4), and the owner checks of `guest_memory` on both copies are what keep one kernelet's descriptor from naming another's frame (invariant I2).

## The ownership-transfer extension

The two copies per packet are the cost of not sharing memory. The booted prototype of the earlier design moved ownership of a buffer between instances instead, at 104, 177 and 94 cycles to create, send and destroy a reference, and measured a 4-byte round trip at 9.4 µs against 36.9 µs for virtio-vsock through a microVM (see the Paper's Evaluation section). In this design the same thing would be a **frame move**: the switch, instead of copying a payload, takes a whole grain out of the sender's grant and appends it to the receiver's, rewriting the owner array and both grant tables and mapping it into the receiver's heap window, after which the receiver's driver finds the packet in memory it now owns. It needs a payload that fills a grain, a mapping-count check on the sender's side so that a frame the sender still maps to a process is never moved, and a `JOB_GRANT`-like notification on the receiver's side; and it changes the memory-only-grows assumption (register A1) for the sender. It is left out of the first version and listed for the Limitations chapter, with the copy path as the baseline it must beat.

## What a tenant sees

`AF_VSOCK` sockets with the kernelet's CID, the host at CID 2, and connections to other sandboxes by their CIDs if the endovisor's policy allows them; connection reset when a peer sandbox dies. Throughput and latency are two copies and two device-thread hops per packet between kernelets, one of each between a kernelet and the host, which the Evaluation chapter measures against virtio-vsock in a microVM.

## Costs

- Per packet: one or two copies under `guest_memory`, one device-thread wakeup per hop, one `raise_irq` and one worker wakeup at the receiver; the switch's table lookups.
- Per connection: one table entry and a bounded host queue, charged to the sender.
- Per kernelet death: one `Rst` per connection and the queue frees.

## What this page decides

- **All communication is vsock over the ordinary device path** (register D37). The alternative, a dedicated cross-kernelet channel with its own service calls, would be a second mechanism to secure and a second thing for tenants to learn; vsock is what their software already speaks.
- **The switch copies in the first version** (register D38); the frame move is the extension, with its preconditions stated, because it changes the ownership model and the memory-growth assumption and must be measured against the copy path before it is adopted.
- **Host-side vsock endpoints are stream descriptors from the endovisor ABI, not a new socket family** (register D39); adding `AF_VSOCK` to the host kernel is more surface than the runtime needs.
