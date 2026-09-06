# The kernelet runtime

*Answers question 4, user side: how is an OCI-compatible kernelet runtime implemented on the endovisor ABI?*

The kernelet runtime is a program in host user space that implements the OCI runtime specification's lifecycle, `create`, `start`, `kill`, `delete` and `state`, over a bundle with a `config.json` and a root file system, so that containerd or podman can drive it as they drive `runc` or `kata-runtime`. Every operation it performs on a sandbox is an operation of the [endovisor ABI](endovisor.md); everything it does inside the sandbox it does through a small **agent**, the kernelet's init process, over a vsock connection. It is trusted by the host as a container runtime is, and by no tenant.

## What runs inside

A kernelet boots the unmodified Linux-ABI kernel with a command line the runtime composes: the virtio MMIO device list of [Devices](virtualizing-ostd/devices.md), `root=/dev/vda`, and `init=/sbin/kernelet-agent`. The agent is a static binary the runtime places in the root file system. It mounts what `config.json` asks for, sets up the process's environment, working directory, user and capabilities from the `process` object, opens the console, and then does what the runtime tells it over vsock port 1024 (chosen): start the container process, start an `exec` process, deliver a signal, report an exit status. It is the same role Kata's agent plays; it is small because the kernel does the rest.

## Lifecycle

| OCI operation | what the runtime does |
|---|---|
| `create <id> --bundle <dir>` | Parses `config.json`. Builds the root file system image (below). Opens `/dev/kernelet`; `KERNELET_CREATE` with the resources translated as in the next table; `KERNELET_ENDPOINT` for the console and the log; `KERNELET_ATTACH` for the block image, the console, the entropy source, vsock, and the network endpoint if the bundle has a network; writes the sandbox descriptor's number and the pid of a holder process into the state directory. The kernelet is `Created`; nothing runs. |
| `start <id>` | `KERNELET_START`. Connects to the agent over `KERNELET_VSOCK_CONNECT` port 1024, sends the `process` object; the agent starts the container process. |
| `kill <id> <signal>` | Sends the signal to the agent, which delivers it to the container process. `SIGKILL` of the container process is the agent's to deliver; killing the *sandbox* is `KERNELET_KILL`, which the runtime uses when the agent does not answer within a timeout. |
| `delete <id>` | `KERNELET_DESTROY` (which kills and waits if needed), removes the image and the state directory. |
| `state <id>` | `KERNELET_STATUS`: `creating`, `created`, `running`, `stopped` from the kernelet's state and the agent's report of the container process. |
| `exec` (a containerd extension) | A second process started through the agent, with its own console endpoint multiplexed over vsock. |

The runtime keeps a holder process per sandbox that owns the sandbox descriptor, since closing the last descriptor destroys the kernelet ([endovisor](endovisor.md), register D42); `delete` is what closes it.

## `config.json` to a kernelet

| `config.json` | kernelet configuration |
|---|---|
| `linux.resources.cpu.cpus`, `.shares`, `.quota`, `.period` | `num_vcpus` from the cpuset's size (the host picks which CPUs), `cpu_weight` from shares, the quota and period as given |
| `linux.resources.memory.limit` | `max_grains = limit / 2 MiB`; `initial_grains` is the runtime's policy, by default a quarter of the limit or 16 grains, whichever is larger (*estimated*; to be tuned against the floor the Evaluation chapter measures) |
| `process` | sent to the agent at `start`: args, env, cwd, user, capabilities, rlimits, terminal |
| `root.path`, `root.readonly` | the block image below, attached read-only if asked |
| `mounts` | bind mounts from the host cannot be given to a kernelet directly; each is either a second block image or, for the standard pseudo-file-systems, done by the agent inside |
| `hostname` | set by the agent |
| `linux.namespaces` | ignored: the sandbox is the namespace |
| `linux.seccomp`, `linux.devices`, cgroup paths | ignored in the first version; a kernelet's isolation does not rest on them |
| `hooks` | `prestart`, `poststart` and `poststop` run on the host as the specification says |

## The root file system

The specification gives the runtime a directory. A kernelet of the first version has no shared file system with the host, only block devices, so the runtime turns the directory into an **ext2 image**: a sparse file created with the host's `mkfs.ext2 -d rootfs`, attached as `/dev/vda`, and deleted at `delete`. The cost is proportional to the root file system's size and is paid at `create`; the runtime caches images by the content hash of the bundle's layers so that the second container from the same image pays nothing. This is the largest practical gap between a kernelet and a container in the first version and is stated as such: a shared file system (`virtiofs`, which the kernel proper's virtio component already has a driver for; checked on the tree: `device/filesystem`) removes the image build and is the planned replacement, on a device model whose backend serves the host directory through the host's own inode API. Until then, `mounts` that bind host directories are unsupported except as further images.

## The network

A kernelet's `virtio-net` device is user-space backed ([Devices](virtualizing-ostd/devices.md), register D25): the runtime holds the network endpoint descriptor and bridges Ethernet frames between it and the host. In the first version the bridge is a user-space NAT in the runtime's own process, in the style of `slirp`: frames from the kernelet are terminated in a user-space TCP/IP stack and forwarded over ordinary host sockets, and replies are framed back. CNI plugins that expect to configure a network namespace and a `veth` pair do not apply, since the host kernel has no such objects (checked on the tree); the runtime instead offers port mapping and outbound connectivity from `config.json` annotations. **[unverified]** (register A11): that user-space NAT throughput is acceptable for the workloads the design targets; assumption A7's in-kernel backend is the alternative.

## The console and the log

The console endpoint is what `process.terminal` attaches to: the runtime connects it to a pseudo-terminal it creates, or to the pipes containerd hands it. The log endpoint carries the kernelet's kernel log to a file in the state directory, which is where an operator looks when a sandbox dies with a panic; the exit status's message from `KERNELET_STATUS` is the last line of it.

## Driving it from containerd

The runtime ships as an OCI runtime binary, `kernelet-runtime`, usable with `runc`-style invocation, and as a containerd shim v2, `containerd-shim-kernelet-v2`, which is the same code behind the shim's ttrpc API with one shim process per sandbox holding the sandbox descriptor. Both are user-space programs and may be written in any language; the design's only requirement is the ABI they speak.

## What a tenant sees

A Linux machine: its own kernel, `/dev/vda` as its root, `eth0` with an address the runtime assigned, a console, `nproc` virtual CPUs and a memory total from the limit. `uname -r` reports the kernelet's kernel. Bind mounts from the host are not available; ports are reachable through the runtime's mapping.

## Costs

- `create`: the image build, proportional to the root file system and cached by content; the kernelet's creation; a handful of `ioctl`s.
- `start`: one `ioctl` and a vsock connection; the kernel's boot inside the kernelet, which the Evaluation chapter measures against a microVM's boot.
- Per network frame: two copies and two wakeups on the endpoint, plus the user-space stack.
- `delete`: destroy, and the image's removal unless cached.

## What this page decides

- **A guest agent as init, over vsock** (register D43). The alternative, having the runtime drive the container process without an agent, has no way to start a process inside a kernel it cannot enter; every VM-based runtime has an agent for this reason.
- **The root file system is an ext2 image in the first version, with `virtiofs` as the planned replacement** (register D44). The alternative of shipping `virtiofs` in the first version puts a shared-file-system backend, the largest device model, on the critical path of the first working sandbox.
- **User-space NAT for the network in the first version** (register D45), following D25; the host has no tap or bridge.
