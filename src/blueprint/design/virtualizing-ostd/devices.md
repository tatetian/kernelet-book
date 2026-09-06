# Devices

*Part of question 2, and the seam with question 4. Virtualizes `io::IoMem` and the DMA objects' device side; specifies what a device model in the endovisor must do. Discharges invariant I2 for frames handed to a device, and bounds the host work a kernelet's I/O induces (invariant I6).*

A kernelet sees devices the way a guest of a microVM does: virtio devices on an MMIO bus, driven by the kernel proper's own virtio drivers, unchanged. What differs is beneath the register file. A register access is not a trap into a VMM but a function call into the endovisor's **device model**, and the memory a driver hands the device in a virtqueue is read and written by that model through a checked accessor rather than by DMA. The drivers, the virtqueue code and the MMIO transport are the kernel proper's (checked on the tree: `kernel/core/comps/virtio`); the bus enumeration, `IoMem`, and everything behind it are what this page virtualizes.

## Enumeration

The virtio MMIO bus on x86-64 already probes devices from the kernel command line in Linux's `virtio_mmio.device=<size>@<base>:<irq>` form (checked on the tree: `transport/mmio/bus/arch/x86.rs`, `probe_from_kernel_cmdline`), then maps the interrupt through the host's interrupt chip. The endovisor composes that line from the kernelet's device descriptors, and the kernelet's bus probe runs unchanged except for the interrupt step, which is one `cfg` line: in the kernelet build the probe calls `IrqLine::alloc_specific(irq)` instead of asking the absent `IRQ_CHIP` to map the line. Each device has a **pseudo-physical MMIO base**, chosen by the endovisor and listed in `BootArgs` beside its size, type and line:

```rust
#[repr(C)] pub struct DeviceEntry {
    pub id: u16, pub kind: u16, pub irq: u8, pub _pad: [u8; 3],
    pub reg_bytes: u32, pub device_type: u32,
    /// The pseudo-physical address the kernelet's bus probe finds the register file at.
    pub mmio_base: u64,
}
```

The bases lie in a range no grain can occupy, above the machine's physical memory, so that a pseudo-physical address can never be confused with a frame.

## `IoMem` as a register file

```rust
// OSTD (kernelet build), the virtualized `IoMem`. Same public API as the host build's.
pub struct IoMem<S = Insensitive> { dev: u16, offset: u32, len: u32, cache: CachePolicy, _s: PhantomData<S> }

impl IoMem {
    /// Finds the device whose register file covers `range` in `BootArgs`; any other range
    /// is `Error::AccessDenied`. No mapping is made.
    pub fn acquire(range: Range<Paddr>) -> Result<IoMem>;
    pub fn slice(&self, range: Range<usize>) -> Self;     // narrows `offset` and `len`
}
impl VmIoOnce for IoMem {
    fn read_once<T: PodOnce>(&self, offset: usize) -> Result<T>   { services().mmio_read(self.dev, self.offset + offset, size_of::<T>(), &mut out); … }
    fn write_once<T: PodOnce>(&self, offset: usize, v: &T) -> Result<()> { services().mmio_write(self.dev, self.offset + offset, size_of::<T>(), v.as_u64()); … }
}
// `read_fallible` and `write_fallible`, behind `VmIo`, are loops of `read_once` and `write_once`
// at the widest aligned width; the transport uses `read_once`/`write_once` for every register
// (checked on the tree: `transport/mmio/device.rs`), so bulk access is only device config space.
```

Every register access is one crossing and one hook call, `KerneletHooks::mmio_read` or `mmio_write`, charged to the kernelet. `IoPort` is absent. `CursorMut::map_iomem` fails, so a tenant cannot `mmap` a register file ([Memory](memory.md)).

## What a device model is

The endovisor implements, per attached device, a **virtio MMIO device model**: the register file of the virtio 1.2 MMIO transport (magic, version 2, device and vendor ids, feature words and selectors, queue selection and size, queue ready, the three queue addresses, notify, interrupt status and acknowledge, status, and the device-specific configuration space at offset 256), backed by a host-side struct, and behind it a **backend** that does the device's work against host resources. The model's `mmio_read` and `mmio_write` are pure state manipulation and never sleep, because the driver holds a spin lock across a register write as it would for real hardware ([service half](../kernelet-api-service.md)). Three writes do more than update state:

- **Queue ready.** The model records the queue's descriptor table, available ring and used ring addresses and its size, and checks that all three lie in the kernelet's grant with `guest_memory`; a queue outside the grant is never marked ready and the driver sees the device fail.
- **Notify.** The model walks the available ring through `guest_memory`, collecting up to the queue's size of descriptor chains; for each chain it reads the descriptors, checks every buffer address and length against the grant, bounds the chain length and the total bytes, and copies the chain's description into a host-side request. Then it hands the batch to the device's **device thread** and returns. A chain that fails a check is completed at once with the device's error status in the used ring, and the request is never seen by the backend; a bad descriptor fails one request, it does not kill the kernelet.
- **Interrupt acknowledge.** Clears the bits the driver acknowledges.

The **device thread** is a host kernel thread the endovisor spawns per device (`ThreadOptions` on the tree), adopted into the kernelet's scheduling group so its time is the kernelet's, holding the host objects the device needs, opened at attach time on the runtime's process ([control half](../kernelet-api-control.md), assumption A5). It takes requests from the model's queue, performs them, writes results into the kernelet's buffers and the used ring through `guest_memory`, which pins the grains for the duration of each write, sets the interrupt status bit, and calls `Kernelet::raise_irq` on the device's line. The kernelet's worker then runs the driver's queue callback, which pops the used ring and completes the I/O ([Interrupts and time](interrupts-and-time.md)).

**Memory movement.** A read from a block device is one copy: the device thread reads the backing file's data through the host's inode `read_at` into the kernelet's buffer inside `guest_memory`, through the host's linear map; there is no intermediate DMA buffer unless the host path needs one, and where it does, the bounce memory is bounded per request and charged with `charge_host_bytes`. A write is the mirror. This is the same number of copies a microVM pays with an in-kernel backend, and one fewer than a user-space device model.

**Bounds, for invariant I6.** Per device: queue size at most 256 entries (the model's maximum, chosen); requests in flight at most the queue size; bytes in flight at most the queue size times the maximum chain bytes, 1 MiB for block, 64 KiB for network (chosen, to be tuned); one device thread. Host memory a request holds is charged. Host CPU time on the device thread is charged through adoption. What is not charged is the host's physical interrupt handling for the real device beneath the backing file, exactly as a hypervisor's is not charged to a guest, and I/O bandwidth is metered only by these queue bounds.

## The devices of the first version

| device | virtio type | backend in the endovisor | what it costs |
|---|---|---|---|
| block | `virtio-blk` | a host file or block device, read and written with the host inode API on the device thread; flush maps to `sync` | one copy per request |
| console | `virtio-console` | a pipe to the kernelet runtime through the [endovisor ABI](../endovisor.md); the runtime attaches a terminal | one copy per byte run |
| entropy | `virtio-rng` | the host's random source | none beyond the copy |
| vsock | `virtio-vsock` | the host-side vsock model of [Channels](../channels.md): connections to the runtime and to other kernelets | see Channels |
| network | `virtio-net` | a user-space backend: frames are shuttled to and from the kernelet runtime over the endovisor ABI, and the runtime bridges them into a host socket | two copies and two wakeups per frame |

The network backend is user-space in the first version because the host kernel has no tap device and no bridging in its network stack (checked on the tree: nothing under `kernel/core/src/net` creates or bridges interfaces), so an in-kernel backend would have to add both; **[unverified]** (register A7): whether a host-side software interface registered with `aster-network` and routed by the host's stack would serve instead, which would save the two wakeups. A shared file system (`virtiofs`) is the natural way to give a kernelet a root file system without a block image and is left for a later version; `mlsdisk` and the other host-only device components never appear inside a kernelet.

## `DmaStream` and `DmaCoherent` on the device side

The driver side of the DMA objects is on the [Memory](memory.md) page: frames from the grant, `daddr` equal to `paddr`, no synchronization. On the device side there is no DMA engine at all: a descriptor's address is a physical address in the kernelet's grant, the model checks it against the owner array through `guest_memory`, and the device thread reads or writes it through the linear map with the grain pinned. `sync_to_device` and `sync_from_device` are no-ops because the CPU that wrote the buffer and the CPU that reads it are coherent. This is what "virtio over function calls" means: the descriptor format, the rings and the drivers are the specification's, and the device is a thread.

## What a tenant sees

A virtio MMIO bus with the devices the runtime attached: `/dev/vda` and its partitions, `hvc0`, `/dev/hwrng`, `eth0`, `/dev/vsock`. `lspci` shows nothing, since there is no PCI. Device performance is the device thread's plus one worker wakeup per interrupt, which the Evaluation chapter measures against virtio in a microVM; a device's registers cannot be mapped into a process, and no device offers memory to map.

## Costs

- Per register access: one crossing and one hook, *estimated* at 50 cycles; a virtio driver makes a handful per request outside the notify.
- Per notify: the available-ring walk under `guest_memory`, bounded by the queue size, and one device-thread wakeup.
- Per completion: the used-ring write under `guest_memory`, one `raise_irq`, and one worker wakeup.
- Per device: one host kernel thread with its stack, one model struct, the host objects behind the backend.
- Per request: bounded host memory, charged.

## What this page decides

- **Devices are enumerated from the kernel command line the endovisor composes** (register D23), so the kernel proper's MMIO bus probe is reused with one `cfg` line for the interrupt step. The alternative, a kernelet-specific bus that reads `BootArgs` directly, is a second probe to maintain.
- **Bad descriptors fail the request, never the kernelet** (register D24). A guest driver that hands a device an address it does not own is a bug in the tenant's kernel, and the microVM answer, an I/O error, is the right one; killing the sandbox would let a driver bug become a denial of service the tenant can trigger at will.
- **The first version's network is user-space backed** (register D25), because the host has no tap or bridge; the in-kernel alternative is A7.
