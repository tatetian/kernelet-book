# The endovisor

*The one component that knows both worlds: a Linux kernel module that loads kernelet images, implements the service table over Linux, carries out the life cycle, and offers the kernelet runtime a device to drive it all. This page also holds the complete list of what the design asks of Linux.*

## What it is

The **endovisor** is a loadable Linux kernel module, `kernelet.ko`, written in C. It is trusted exactly as the rest of Linux is. It is *endo-* because it lives inside the host kernel, beside the kernelets it manages and at their privilege level, where a hypervisor would sit beneath its guests. The relationship it has with user space is the one KVM has with a virtual machine monitor, with one difference: the device models, which for KVM live in the monitor, live in the endovisor, a function call away from the kernelets they serve.

It has eight parts, and each is specified on the page that needs it.

| part | what it does | specified on |
|---|---|---|
| **loader** | registers kinds; maps an instance's shared text and private data; relocates | [Builds and images](builds-and-images.md) |
| **program loader and root carrier** | claims the sandbox file when it is executed; clones every carrier | [Tasks](virtualizing-ostd/tasks.md#root) |
| **gate operations** | the syscall hook and the resume hook; the stack switch; `user_run` | [User mode](virtualizing-ostd/user-mode.md) |
| **service half** | the twenty-one services over Linux, with the depth and seat bookkeeping | [service half](kernelet-api-service.md) |
| **memory** | grains, the owner array, the fault handler that fills Linux's page tables from the model | [Memory](virtualizing-ostd/memory.md) |
| **containment** | the dying mark, eviction, the die notifier, the exit stub, destroy | [Faults](faults-and-reclamation.md) |
| **device models and the channel switch** | virtio register files, device threads, vsock | [Devices](virtualizing-ostd/devices.md), [Channels](channels.md) |
| **the device node** | the interface to the runtime | below |

## What it asks of Linux {#patch}

This is the whole ledger. Everything else the endovisor uses is already exported to modules in Linux v6.12, and each use is linked where it is described.

**A patch to the generic entry layer: the gate.** A pointer in the task structure, one bit in the syscall-work mask, a call after seccomp in `syscall_trace_enter()`, and a call at the top of `exit_to_user_mode_loop()`. The generic entry layer is shared by x86-64, RISC-V, s390 and LoongArch, so the gate is not an x86 patch.

**Four exports.**

| symbol | why | what happens without it |
|---|---|---|
| `kernel_clone` | create a carrier: a task that starts in the endovisor and can enter user mode | no kernelet task can run a tenant |
| `set_memory_rox` | make an instance's text executable | no kernelet can run at all |
| `set_memory_rw` | undo the side effect of the above on the direct map when a kind is unregistered and its text frames are freed | an unregistered kind leaks read-only frames into Linux's allocator |
| `set_memory_ro` | protect an instance's relocated tables | hardening only |

**The patch as built** for the [prototype](prototype.md#hello), against Linux v6.12: 103 added lines in 8 files and none removed (*measured on the booted prototype*). Of those, 38 are a new header and 12 a configuration option; the code in Linux's paths is the two hunks below, and everything is inert for a task whose pointer is null.

```c
/* include/linux/kernelet.h (new) */
struct kernelet_gate_ops {
	bool (*syscall)(struct pt_regs *regs);	/* true: serviced; skip Linux's dispatch */
	void (*resume)(struct pt_regs *regs);	/* on the way out, while exit work is pending */
};
struct kernelet_gate { const struct kernelet_gate_ops *ops; };

/* include/linux/sched.h: struct task_struct */
	struct kernelet_gate		*kernelet;	/* inherited by fork */

/* include/linux/thread_info.h, include/linux/entry-common.h */
	SYSCALL_WORK_BIT_KERNELET,			/* and its mask, added to SYSCALL_WORK_ENTER */

/* kernel/entry/common.c: syscall_trace_enter(), after the seccomp block */
	if (work & SYSCALL_WORK_KERNELET) {
		if (current->kernelet->ops->syscall(regs))
			return -1L;
	}

/* kernel/entry/common.c: exit_to_user_mode_loop(), first in the loop body */
		if (unlikely(current->kernelet))
			current->kernelet->ops->resume(regs);

/* kernel/fork.c, arch/x86/mm/pat/set_memory.c */
EXPORT_SYMBOL_GPL(kernel_clone);
EXPORT_SYMBOL_GPL(set_memory_rox);
EXPORT_SYMBOL_GPL(set_memory_rw);
EXPORT_SYMBOL_GPL(set_memory_ro);
```

**One operator requirement.** The machine must not be set to panic, or to capture a crash dump, on an oops ([why](faults-and-reclamation.md#fault)).

**One build configuration still open.** A Linux built with type-checked indirect branches ([assumption A19](builds-and-images.md#audit)).

**Three interactions with the rest of Linux that an operator should know.** A host security module sees each carrier create a shared, writable, executable mapping of an endovisor file, and its policy must allow that to the sandbox's user. Live patching decides that a task is safe to patch by unwinding its stack; a carrier that is preempted while on its kernelet stack cannot be unwound, so a patch transition waits until that carrier next runs a service or returns to user mode, and waits indefinitely on a runaway kernelet until it is killed. **[unverified]**: neither has been tried. And suspending the machine needs every task to stop at a point Linux considers safe. The carriers' sleeps are marked freezable as well as killable, which covers a carrier that is waiting, and the service prologue and the resume hook give Linux its chance for a carrier that is running; a kernelet that stays in its own code for longer than Linux's freezing timeout, twenty seconds by default, makes that suspend attempt fail.

**Everything a sandbox costs the host is charged to its control group**, by one of two routes, and the list is the same list that [destroy](faults-and-reclamation.md#destroy) walks: the grant, the instance's private pages, its shared pages and metadata region, carrier records, kernelet stacks, log ring, device inboxes and channel queues are allocated by a member of the group with Linux's accounting flag; carriers and device threads are members, so their processor time, their Linux task structures and stacks, their page tables and their number (`pids.max`) are the group's. The queue of spawn requests is bounded by the sandbox's task limit.

What the design does *not* ask for is as important to an operator: no boot parameter, no particular preemption model, no virtualization support in the kernel, no change to any Linux subsystem's behavior for tasks that are not carriers. A Linux with the patch applied and the module not loaded behaves as it did.

**Would the patch be accepted upstream?** Not in this form, and the design does not depend on it. A version with a chance would present the gate as the in-kernel generalization of Syscall User Dispatch, behind a configuration option, with an in-tree user. The export of `kernel_clone` would be the contentious part, and the fallback is a narrower helper that creates only "a child of the current task that starts in a given function", which is what the endovisor uses it for.

## The device node {#abi}

The endovisor offers user space one character device, `/dev/kernelet`, root-only by default. Opening it and creating a sandbox yields a **sandbox descriptor**; every later operation is an `ioctl` on that descriptor, and closing the last copy of it kills and destroys the sandbox, so a crashed runtime cannot leak one.

| operation | effect |
|---|---|
| `KERNELET_REGISTER_KIND` | hand over an image file; the endovisor checks it and keeps its text for sharing |
| `KERNELET_CREATE` | create a sandbox of a kind, with its seats, memory limits, policy and command line; returns the sandbox descriptor |
| `KERNELET_EXEC_FD` | returns the sandbox's **exec descriptor**, used once, to start it |
| `KERNELET_GRANT` | raise the sandbox's memory ceiling, or push grains to it; the kernelet learns of pushed memory by a `JOB_GRANT` |
| `KERNELET_ATTACH` | attach a virtual device, passing the descriptor of the file, block device or TAP interface behind it |
| `KERNELET_ENDPOINT` | obtain a stream descriptor for the sandbox's log or console |
| `KERNELET_CONNECT`, `KERNELET_LISTEN` | the host's end of a [channel](channels.md) |
| `KERNELET_KILL` | mark the kernelet dying, with a reason |
| `KERNELET_WAIT`, `poll` | learn that it has exited, and why |
| `KERNELET_STATS` | memory granted, service calls, interrupts raised, log records dropped, caught panics |
| `KERNELET_DESTROY` | reclaim everything; legal once the kernelet has exited |
| `KERNELET_UNREGISTER_KIND` | drop a kind with no instances, and return its text frames to Linux |

**Starting is not an `ioctl`.** A sandbox starts when a process executes its **sandbox file**. The file is not on any file system: it is a small in-memory file that the endovisor itself creates (with Linux's exported [`shmem_file_setup()`](https://elixir.bootlin.com/linux/v6.12/source/mm/shmem.c#L5265)), containing a magic number, and the runtime receives it only as the exec descriptor, which it executes with `execveat()`. The endovisor's [program loader](virtualizing-ostd/tasks.md#root) recognizes the magic and identifies the sandbox *by the file object*, which it made, not by a secret that could leak. It then checks that the sandbox is in the *created* state, that the executing process has *no new privileges* set and is not gaining privileges by this `exec`, and that its control group is not the root group; marks the descriptor used; and turns the process into the root carrier. Starting by `exec` is what lets the runtime prepare that process with ordinary Linux tools first, because everything it sets up is inherited by every carrier: the control group that bounds and accounts the sandbox, the user and the namespaces it runs as, and the seccomp filter.

## The life of a sandbox, in order

1. The runtime registers the kind (once per machine), creates the sandbox and attaches its devices.
2. The runtime forks a child, which enters the sandbox's control group, drops to the sandbox's credentials, installs the [seccomp filter](virtualizing-ostd/user-mode.md), and executes the sandbox file.
3. The endovisor loads the instance, grants its initial memory (now charged to that control group), and makes the child the root carrier, which clones the boot task's carrier and the workers' carriers.
4. vOSTD initializes; the kernel proper boots, mounts its root file system from the virtio disk, and starts the tenant's `init`, whose kernelet task's first `user_run` creates the first tenant address space.
5. The sandbox runs. Every tenant thread is a carrier; every system call goes through the gate to the kernelet; every page of tenant memory enters Linux's page tables through the endovisor's fault handler, checked against the grant.
6. The kernel proper powers off, or the runtime kills the sandbox. The endovisor marks it dying, stops every carrier, reports the exit, and on `KERNELET_DESTROY` returns the memory.

## Size

**[unverified]**: the endovisor has not been written. The prototype's module, which implements the gate operations, the program loader and root carrier, carriers, the stack switch, the memory areas with the model walk, lifelines, eviction, and the services two small kernels need, for one kernelet, is 2,335 lines of C (*measured on the booted prototype*). The device models are the largest remaining part; their Rust equivalents for the other host are *estimated* at a few thousand lines.

## What this page decides

- **The endovisor is one C module, and Linux mode requires a patched Linux** (register D79, kept, and D80, revised): the gate and four exports. An unpatched Linux is ruled out by function, not speed: without the gate, a tenant's second process makes its system calls to Linux.
- **A sandbox starts by `exec` of a sandbox file and is owned by a descriptor** (register D105). The alternative, a start `ioctl` that turns the calling thread into the root carrier, leaves the runtime's own address space in the root carrier, to be copied into every clone.
