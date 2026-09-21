# The kernelet runtime

*The program an operator actually runs: a container runtime that gives each container a kernelet. It is ordinary host user space, trusted as a container runtime is trusted, and everything it does to a sandbox it does through the endovisor's device and Linux's own tools.*

## What it is

The **kernelet runtime** implements the Open Container Initiative's runtime interface, the five verbs `create`, `start`, `kill`, `delete` and `state` over a *bundle* (a directory with a `config.json` and a root file system). That is the interface `runc` implements, so containerd, Podman or Kubernetes can use kernelets by naming a different runtime, with nothing else changed. Its model is the one Kata Containers uses for virtual machines: the sandbox boots at `create`, and the container's process is something an agent inside the sandbox starts later.

No tenant sees the runtime or trusts it. The host trusts it to configure sandboxes correctly, as it trusts `runc`.

## What runs inside a sandbox

The kernel proper, with a command line the runtime composes: the list of virtio devices, the root device, and `init=/sbin/kernelet-agent`. The **agent** is a small static program that the runtime places in the root file system. As the sandbox's first process it mounts what `config.json` asks for, sets the hostname, configures the network interface, and then takes orders from the runtime over a [vsock connection](channels.md): start the container's process with this environment and these limits, start another (`exec`), deliver a signal, report an exit status, carry the standard streams. It is small because a real kernel is doing the rest.

The root file system reaches the sandbox as a disk image. The runtime builds an ext2 image from the bundle's root directory, caches it by content, and attaches it as a read-only virtio disk under a writable overlay.

## `create`, step by step

Each step is either an operation on the [endovisor's device](endovisor.md#abi) or ordinary Linux administration, and the order is what makes the [inheritance](virtualizing-ostd/tasks.md#root) work.

1. **Check the host.** Refuse if `/proc/sys/kernel/panic_on_oops` is set ([why](faults-and-reclamation.md#fault)), or if the endovisor's device is missing.
2. **Parse the bundle**, and reject what cannot be honored.
3. **Make a control group** for the sandbox (cgroup v2) and write the bundle's processor and memory limits into it. These are Linux's own controls, and they bound the kernelet itself, not just the tenant's processes: every task of the kernelet and every page of its grant will belong to this group. Three settings are not optional. `pids.max` is set a little above the sandbox's task limit, so that carriers cannot exhaust the machine's process identifiers. `memory.max` is set, and the operator keeps the sum over all sandboxes within the machine's memory, because a grant is kernel memory that Linux's *global* out-of-memory killer does not attribute to the carriers, so global pressure would otherwise be paid by other processes. And `memory.oom.group` is set, so that when the group's own limit is hit Linux ends the whole sandbox and not one carrier.
4. **Open `/dev/kernelet`** and `KERNELET_CREATE` with the kind, the number of seats, the memory ceiling and the command line. Ask for the sandbox's **exec descriptor** with `KERNELET_EXEC_FD`.
5. **Open the backends** under the runtime's own credentials (the disk image, a TAP interface for the network) and `KERNELET_ATTACH` each, passing the descriptor. Obtain the log and console endpoints. `KERNELET_LISTEN` on the agent's port.
6. **Fork the process that will become the root carrier.** In the child: move into the control group; enter the namespaces and the user the sandbox should run as, a user identity dedicated to this sandbox, so that no other process on the host may signal or inspect its carriers; leave the address-space limit unlimited (protection against `ptrace` and `/proc` inspection by same-user processes comes from the exec descriptor being [execute-only](endovisor.md#abi), since anything the child set for itself would be reset by the `exec`); set *no new privileges* and install the seccomp filter that closes the [legacy vsyscall page](virtualizing-ostd/user-mode.md); and execute the exec descriptor with `execveat()`. The endovisor's program loader takes over from there, and the child never returns to user space.
7. **Wait for the agent** to connect, and send it the container's configuration. If anything has failed, `create` fails and the sandbox is destroyed, as the specification requires.
8. **Start a holder process** that keeps the sandbox descriptor and the agent connection open, and listens on a Unix socket in the state directory. Closing the last sandbox descriptor destroys the sandbox, so something must hold it between invocations of the runtime.

The seccomp filter is worth writing out, because it is the only thing between a tenant and three Linux system calls:

```c
/* allow everything; trap a call into the legacy vsyscall page */
BPF_STMT(BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, instruction_pointer) + 4),  /* high word */
BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, 0xffffffff, 0, 3),
BPF_STMT(BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, instruction_pointer)),      /* low word  */
BPF_JUMP(BPF_JMP | BPF_JGE | BPF_K, 0xff600000, 0, 1),
BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_TRAP),
BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ALLOW),
```

Every ordinary system call of a carrier passes this filter with *allow* and then meets the [gate](virtualizing-ostd/user-mode.md), which hands it to the kernelet. **[unverified]**: the filter is written from the documented layout of seccomp's input and has not been run.

## The other verbs

- **`start`** tells the agent to start the container's process.
- **`kill <signal>`** asks the agent to deliver the signal inside. If the agent does not answer in time, the runtime kills the *sandbox* with `KERNELET_KILL`.
- **`delete`** destroys the sandbox (`KERNELET_KILL` if it is still running, a wait for it to exit, then `KERNELET_DESTROY`), ends the holder, and removes the control group and the state directory.
- **`state`** reports the container's status from the kernelet's state and the agent's report. The process identifier it reports is the holder's, because the container's process has no identifier the host could use: on the host it is one of many carriers, and inside the sandbox it has a process identifier only the kernelet knows.

One policy belongs to the runtime because only it can enforce it: **creation is rate-limited per tenant.** Creating an instance changes page permissions, which flushes the TLB of every processor on the machine ([Builds and images](builds-and-images.md)), so a tenant that could make its sandbox restart in a tight loop could tax every other workload. The runtime spaces restarts out, and refuses them beyond a budget.

## What the operator sees on the host

A sandbox appears as a control group containing one process per kernelet task, all descended from the root carrier, none of which can be traced or signaled usefully one at a time ([why](virtualizing-ostd/tasks.md)). Its memory appears as kernel memory charged to the group. Its log is a stream from the endovisor; its console is another. `cgroup.kill` on the group ends the sandbox, which is the same thing `KERNELET_KILL` does by another route.

## Networking

The first version gives a sandbox a TAP interface, which the runtime creates and connects to whatever the container network expects (a bridge, a veth pair into a network namespace). This is simpler than on the Asterinas host, which has no such machinery and falls back on a user-space translator in the runtime.

## What this page decides

- **The runtime is an OCI runtime with a guest agent, booting the sandbox at `create`** (register D43 and D54, kept).
- **The runtime prepares a process and lets it execute the sandbox file** (register D105): control group, credentials, namespaces and seccomp filter are set with Linux's own tools and inherited by every carrier.
- **The network backend is a TAP interface** (register D110), replacing the other host's user-space translator.
