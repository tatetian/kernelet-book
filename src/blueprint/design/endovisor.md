# The endovisor

*Answers question 4, kernel side: how is the endovisor implemented on OSTD, and what user-space ABI does it expose to the kernelet runtime?*

The endovisor is a component of the host kernel, the blue box beside "Linux functionality" in the [figure](index.md): safe Rust in the kernel proper's host configuration, with no `unsafe` of its own, built over two things and nothing else. Downward it uses the [control half](kernelet-api-control.md) of OSTD's kernelet API to create, feed, watch, kill and destroy kernelets and to receive their hooks; sideways it uses the host kernel's ordinary Linux functionality, files, threads, pipes, the random source, to give those hooks something to do. Upward it exposes the **endovisor ABI**: a character device, `/dev/kernelet`, whose operations are how the kernelet runtime in host user space does everything it does. It is to the kernelet API what a VMM is to KVM, except that it lives in the kernel and its device models are function calls away from the kernelets they serve.

## Where it lives

```
kernel/core/comps/endovisor/            a component like `block` or `network`, host build only
  src/lib.rs                            #[init_component]: registers images, creates the device node
  src/images.rs                         include_bytes! of every kernelet image the build produced
  src/device.rs                         `/dev/kernelet`: the misc character device and its ioctls
  src/sandbox.rs                        one `Sandbox` per created kernelet: hooks, devices, endpoints
  src/models/{blk,console,rng,vsock,net}.rs   the virtio MMIO device models and their device threads
  src/vsock_switch.rs                   the host-wide switch of [Channels](channels.md)
  src/policy.rs                         limits, defaults, who may create
```

It registers itself through the component system the kernel proper already has (`#[init_component]` and `.init_array`; checked on the tree), at the initialization stage at which the misc character devices are created (`init_in_first_kthread`, `device/misc/mod.rs`), and it uses the kernel's own device registry, `Device` and `PerOpenFileOps` traits and typed `ioctl` helpers (checked on the tree: `device/misc/tdxguest.rs` is the pattern, `util/ioctl`).

## The `Sandbox`

One object per created kernelet, owned by the file description that created it:

```rust
// endovisor/src/sandbox.rs
pub(crate) struct Sandbox {
    kernelet: Arc<Kernelet>,                       // the control-half object
    hooks: Arc<SandboxHooks>,                      // implements `KerneletHooks`
    devices: Vec<AttachedDevice>,                  // model + backend + device thread, per device
    console: Option<Endpoint>,                     // the virtio-console backend's host end
    log: Endpoint,                                 // the log hook's host end
    net: Option<Endpoint>,                         // the user-space network backend's host end
    exit: Once<ExitStatus>,
    owner: Uid,                                    // who created it; who may operate on it
}

struct SandboxHooks { models: RwLock<Vec<Arc<dyn DeviceModel>>>, log: Endpoint, console: Endpoint, policy: Policy }
impl KerneletHooks for SandboxHooks {
    fn mmio_read(&self, k: &Kernelet, dev: DeviceId, off: u32, width: u8) -> u64 { self.models[dev].read(off, width) }
    fn mmio_write(&self, k: &Kernelet, dev: DeviceId, off: u32, width: u8, v: u64) { self.models[dev].write(k, off, width, v) }
    fn log(&self, k: &Kernelet, level: LogLevel, module: &str, text: &str) { self.log.push_line(level, module, text) }
    fn console_write(&self, k: &Kernelet, bytes: &[u8]) { self.console.push(bytes) }
    fn on_grant_exhausted(&self, k: &Kernelet) -> u32 { self.policy.extra_grains(k) }
    fn on_oops(&self, k: &Kernelet, task: TaskName, msg: &str) { self.log.push_line(LogLevel::Error, "oops", msg) }
    fn on_dying(&self, k: &Kernelet, why: &ExitReason) { for m in self.models.read().iter() { m.cancel() } ; vsock_switch::reset_all(k.id()) }
    fn on_exited(&self, k: &Kernelet, st: &ExitStatus) { /* record; wake pollers of the sandbox fd */ }
}
```

An **`Endpoint`** is a pair of bounded byte queues in host memory with a wakeup each way, one end held by the sandbox and the other surfaced to user space as a file descriptor; it is what a console, a log stream, a user-space network backend and a vsock stream are made of. Its bytes are charged to the kernelet with `charge_host_bytes`, and its bound is the policy's.

A **`DeviceModel`** is the virtio MMIO register file of [Devices](virtualizing-ostd/devices.md) over a backend:

```rust
pub(crate) trait DeviceModel: Send + Sync {
    fn read(&self, off: u32, width: u8) -> u64;                       // never sleeps
    fn write(&self, k: &Kernelet, off: u32, width: u8, v: u64);        // never sleeps; a notify hands work to the thread
    fn cancel(&self);                                                  // from `on_dying`: stop the thread's outstanding I/O
}
```

The device thread behind a model is a host kernel thread (`ThreadOptions::new(…).spawn()` on the tree), started at attach and stopped at `cancel`, adopted into the kernelet's group with `adopt_current_task` for its whole life. The backends of the first version and the host objects they hold, opened on the runtime's process at attach:

| backend | host object held | the device thread's work |
|---|---|---|
| block | an inode of a regular file or a block device, opened read-write by the runtime and passed as a descriptor | `read_at` and `write_at` on the inode inside `guest_memory`; `sync` for flush |
| console | an `Endpoint` | moves bytes between the virtio-console queues and the endpoint |
| entropy | nothing | fills request buffers from the host's random source |
| vsock | the switch | transmit-queue packets into the switch, switch deliveries into the receive queue |
| network | an `Endpoint` carrying Ethernet frames | moves frames between the virtio-net queues and the endpoint; the runtime bridges the other end into the host's network |

Assumption A5 applies to every row: the inode and endpoint operations are driven by a kernel thread without a process. If a host path turns out to need one, the thread borrows the runtime's process context for that call.

## The endovisor ABI

The ABI is the misc character device `/dev/kernelet` and two kinds of file descriptor it hands out: a **sandbox descriptor**, one per created kernelet, and **endpoint descriptors** for streams. Every operation is an `ioctl` in the typed form the kernel proper uses (`Ioctl<MAGIC, NR, IS_MODERN, D>` with `InData`, `OutData` and `InOutData`; checked on the tree), with magic `'K'`. Permission to open `/dev/kernelet` is the device node's mode; a sandbox descriptor is usable only by the user that created it, and the policy caps how many kernelets, grains and CPUs one user may hold.

**On `/dev/kernelet`:**

```rust
/// Creates a kernelet in state `Created` and returns a sandbox descriptor.
const KERNELET_CREATE: Ioctl<'K', 0x01, true, InOutData<CreateArgs>>;
#[repr(C)] pub struct CreateArgs {
    pub image: u16,                  // kind: 0 = the Linux kernelet
    pub num_vcpus: u16,              // the host picks the CPUs from the caller's allowed set
    pub initial_grains: u32, pub max_grains: u32,
    pub cpu_weight: u32, pub cpu_quota_us: u32, pub cpu_period_us: u32,   // 0 = uncapped
    pub oops_budget: u32, pub preempt_off_ticks: u32, pub log_bytes_per_sec: u32, pub idle_tick_hz: u32,
    pub cmdline: *const u8, pub cmdline_len: u32,   // read during the call
    pub out_cid: u32,                // written: the kernelet's vsock CID
}
/// Enumerates registered kinds.
const KERNELET_LIST_IMAGES: Ioctl<'K', 0x02, true, OutData<[ImageInfoRaw; 8]>>;
```

**On a sandbox descriptor**, before `START`:

```rust
/// Attaches a virtual device; returns its index on the kernelet's MMIO bus.
const KERNELET_ATTACH: Ioctl<'K', 0x10, true, InOutData<AttachArgs>>;
#[repr(C)] pub struct AttachArgs {
    pub kind: u16,                   // BLOCK, CONSOLE, RNG, VSOCK, NET
    pub backing_fd: i32,             // BLOCK: a file or block device; CONSOLE, NET: an endpoint descriptor from `ENDPOINT`; else -1
    pub flags: u32,                  // BLOCK: read-only; NET: the MAC address in `arg`
    pub arg: u64,
    pub out_index: u16,              // written
}
/// Creates a two-ended byte stream and returns the user-space end; the sandbox keeps the other.
const KERNELET_ENDPOINT: Ioctl<'K', 0x11, true, InOutData<EndpointArgs>>;   // kind: CONSOLE, LOG, NET
```

**On a sandbox descriptor**, at any time:

```rust
const KERNELET_START:   Ioctl<'K', 0x20, true, NoData>;
const KERNELET_KILL:    Ioctl<'K', 0x21, true, InData<u32>>;                // a reason code the status reports
const KERNELET_GRANT:   Ioctl<'K', 0x22, true, InOutData<u32>>;             // grains asked, grains given
const KERNELET_BUDGET:  Ioctl<'K', 0x23, true, InData<BudgetArgs>>;
const KERNELET_STATS:   Ioctl<'K', 0x24, true, OutData<StatsRaw>>;          // `KerneletStats` plus state and CID
const KERNELET_STATUS:  Ioctl<'K', 0x25, true, OutData<StatusRaw>>;         // state, and the exit status once exited
/// A vsock stream to the kernelet: connect to `port`, or listen on host port `port` for one connection from it.
const KERNELET_VSOCK_CONNECT: Ioctl<'K', 0x30, true, InOutData<VsockArgs>>; // returns an endpoint descriptor
const KERNELET_VSOCK_LISTEN:  Ioctl<'K', 0x31, true, InOutData<VsockArgs>>;
/// Reclaims everything. Also what closing the last sandbox descriptor does, after a kill and a wait.
const KERNELET_DESTROY: Ioctl<'K', 0x2f, true, NoData>;                     // EBUSY while a pin or a device thread is outstanding
```

A sandbox descriptor is pollable: readable when the kernelet has exited, so that the runtime waits with `poll` rather than a blocking `ioctl`. Endpoint descriptors are ordinary readable, writable, pollable streams. Closing the last sandbox descriptor of a running kernelet kills it, waits for it to exit, and destroys it, so that a runtime that crashes leaves no sandbox behind; a destroy that finds a pin outstanding is retried by a host kernel thread until it succeeds.

## Policy

The endovisor is where the host's policy lives, and the control half has none. In the first version: a per-user cap on live kernelets, on total grains and on total virtual CPUs; the set of host CPUs kernelets may use, from which `CREATE` picks; the default `KerneletPolicy` values; and `on_grant_exhausted`'s answer, which is to grant up to the user's remaining cap. Which kernelets may reach which over vsock is the switch's policy, per pair of CIDs, default allow within one user and deny across.

## What the endovisor is trusted for

Everything. It runs in ring 0 in the host kernel and holds every kernelet's hooks; a bug in it is a host bug. What limits the damage a *tenant* can do through it is that every tenant input reaches it through a checked path: register accesses through the service half's bounds, descriptors through `guest_memory`'s owner checks, packets through the switch's credit. Its own code is safe Rust with `forbid(unsafe_code)` like the rest of the kernel proper, and it is the second-largest piece of new code in the design after the kernelet build of OSTD, *estimated* at 8,000 to 12,000 lines with the five device models.

## Costs

- Per sandbox: the `Sandbox` object, its endpoints' queues, one device thread per device with a 512 KiB stack, and the kernelet's own cost from the [control half](kernelet-api-control.md).
- Per `ioctl`: a system call on the host; none is on a kernelet's fast path.
- Per byte through an endpoint: one copy into the queue and one out, one wakeup each way when the queue was empty or full.

## What this page decides

- **The endovisor is a component of the kernel proper, in safe Rust, over the control half** (register D40), not a module of OSTD: it holds Linux functionality, files and threads, that OSTD does not have and should not.
- **The endovisor ABI is one character device with typed `ioctl`s and pollable descriptors** (register D41), the shape of `/dev/kvm`, because a container runtime already knows how to drive that shape and it needs no new syscalls.
- **Closing the last sandbox descriptor destroys the kernelet** (register D42), so that no crashed runtime leaks a sandbox; the price is that a runtime that wants a kernelet to outlive it must hand the descriptor to another process first.
