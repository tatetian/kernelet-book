# Boot, power, panic, and the rest

*The remaining pieces of OSTD's interface: how a kernelet starts and stops, where its log goes, what happens when it panics, and which parts of the machine it can still touch directly.*

## A kernelet is entered, not booted

There is no firmware, no boot loader and no processor bring-up. The endovisor [loads the image](../builds-and-images.md), prepares the shared pages, and asks the root carrier for the first carrier ([Tasks](tasks.md#root)). That carrier's kernelet task is the **boot task**, and its first act is to call the image's entry point, `_kernelet_entry(services, boot_args)`, on a fresh kernelet stack.

vOSTD's initialization is OSTD's with everything a machine needs removed. In order, it:

1. stores the service table pointer and reads the **boot arguments**, a read-only page holding the kernelet's identity, its number of virtual CPUs, the direct-map base, the locations of the other shared pages, the device list and the kernel command line;
2. parses the command line and initializes logging;
3. reads the grant table and hands the initial runs to its frame allocator;
4. sets up the per-seat copies of its per-CPU data and its task table;
5. releases the workers with `task_unpark`; the endovisor created them suspended, and told the kernelet their names in the boot arguments, so that no interrupt could be delivered before step 4;
6. runs the image's initializers, which is how the kernel proper's components register themselves;
7. calls the kernel proper's `main`.

**Boot information.** `boot::boot_info()` returns a record synthesized from the boot arguments: a boot-loader name of `"kernelet"`, the command line, and one usable memory region per initial run, so that the kernel proper's idea of total memory is its initial grant. There is no ACPI table, no framebuffer and no initial RAM disk; an initial file system arrives as a block device.

**Secondary processors.** On a machine, OSTD starts the other processors and runs a registered entry function on each. vOSTD spawns one task per additional virtual CPU instead, each restricted to that virtual CPU's [seat](tasks.md#seats), which runs the entry function and exits. They run concurrently with `main`, as processors do.

**When `main` returns.** OSTD's start-up code calls `Task::yield_now()` after `main`, from a context that is not itself a task, and on a machine that call never returns while any task exists. vOSTD keeps that meaning: from the boot context, `yield_now` gives up the seat and sleeps until the kernelet has no tasks left. The prototype found this the hard way ([findings](../prototype.md#findings)).

## Power

`power::poweroff(code)` and `power::restart()` become the service [`stop`](../kernelet-api-service.md#abi) with the kind `KLET_STOP_EXIT`, the code, and no message. It never returns. The endovisor marks the kernelet dying, records the exit code, and [ends every carrier](../faults-and-reclamation.md). The runtime learns the code from the endovisor's device. A restart is an exit whose code has its top bit set, which asks the runtime to create the sandbox again.

## Log and console

`log_write(level, module, text)` hands a record of at most 1 KiB to the endovisor, which copies it into a per-sandbox ring that the runtime reads, and drops records beyond the sandbox's configured bytes per second. A kernelet's log does not go to Linux's own log by default: a tenant must not be able to flood the operator's console or push the operator's messages out of the kernel's ring. The prototype, which has one kernelet and no runtime, sends it to `printk`.

## Panic

A panic on one task of the kernel proper is caught by the kernel proper itself, which ends that task and carries on; vOSTD reports it with the service `oops` so that the endovisor can count it against the sandbox's **oops budget**. A panic nothing catches reaches vOSTD's panic handler, which calls `stop` with the kind `KLET_STOP_PANIC` and the message. Unwinding inside a kernelet uses the image's own unwind tables and never crosses into Linux.

## The machine a kernelet can still touch

A kernelet runs in kernel mode, so nothing in hardware stops its code from executing a privileged instruction. What stops it is that the kernel proper cannot express one: it is safe Rust, and vOSTD, the only code in the image that may use `unsafe`, does not offer it one.

| OSTD item | in vOSTD on Linux |
|---|---|
| CPU feature queries | identical: the `cpuid` instruction, read directly |
| timestamp counter | identical: `rdtsc`, read directly |
| port I/O, the interrupt controller, the IOMMU, PCI, ACPI | absent: a use does not compile |
| enabling and disabling interrupts | absent; the "interrupts off" guard is the no-preemption counter, which is sufficient because no kernelet code runs in interrupt context |
| sending inter-processor interrupts | absent; remote TLB flushes go through [`tlb_shootdown`](memory.md#cache) |
| FS base of a tenant thread | virtualized: set through the endovisor on entry to user mode ([User mode](user-mode.md)) |
| floating-point and vector state | never used by kernelet code; a tenant's is Linux's to save and restore |

## What this page decides

- **A kernelet's log goes to a per-sandbox ring, rate-limited, not to Linux's log** (register D103). The alternative is simpler and lets any tenant write to the operator's console.
- **`yield_now` from the boot context waits for the kernelet's last task** (register D104), which is what the call means on a machine.
