# The endovisor as a Linux module

*What the endovisor becomes when the host kernel is Linux: how a kernelet is loaded, where its memory comes from, what its tasks are, and how it is interrupted. Everything on this page runs in an ordinary loadable module, and the only changes it needs of Linux are the exported symbols the [background](background.md) page named.*

The endovisor is defined by what it does, not by where it lives: it creates, schedules, destroys and mediates kernelets ([Terminology](../overview/terminology.md)). In Asterinas mode it is a module of the host kernel crate. In Linux mode it is a Linux loadable module, written in Rust or C, exposing the same `/dev/kernelet` interface to the kernelet runtime that the [endovisor page](../design/endovisor.md) specifies.

## Loading a kernelet

A kernelet **kind** is one image. The endovisor reads it once, at attach time, and keeps it as three things: the text pages, a data template, and a relocation list.

Creating an **instance** is then four steps:

1. **Take pages for the data.** One allocation from Linux's page allocator, sized by the image's writable segment plus one replica of the per-CPU section for each virtual CPU. Copy the template in, zero the rest.
2. **Build the image's address range.** Call `vmap()` with the kind's text pages followed by this instance's data pages. Linux returns one contiguous kernel address for the lot: this instance's image base.
3. **Make the text read-execute.** `vmap()` returns a read-write, non-executable mapping, so the endovisor calls `set_memory_rox()` on the text pages of *this mapping only*, which clears both the write and the no-execute bits and leaves the data pages writable and non-executable. Clearing only the no-execute bit, as the first draft of this chapter said, would leave the text writable *and* executable. `set_memory_rox` is not exported; this is the change Linux mode needs.
4. **Relocate the data.** Walk the image's relocation entries, adding the instance's base to each. The text has none, by construction and by audit.

Then write the two bases the instance needs — the host's direct-map base and this instance's metadata base — into its boot arguments, and call its entry point.

Destroying an instance reverses it: stop its tasks, unmap the image, free the data pages, return the grains. "Stop its tasks" is doing more work in that sentence than Linux will allow, which [the tenant page](tenant.md) explains.

Two costs of this sequence belong here rather than in a footnote. `vmap()` maps at the smallest page size only, so each instance's image occupies its own set of small-page translations even though the underlying text is shared — sharing the physical text saves memory, not translation-buffer entries, and the Design chapter's 2 MiB mapping of the image is lost on Linux. And the call that fixes the text's permissions forces a machine-wide translation-buffer flush, so creating an instance interrupts every processor once.

**Why not let Linux's module loader do this?** Because it would give each instance its own copy of the text. Linux's loader exists to load distinct modules, not many instances of one, and the memory it loads them into is a 1520 MB region shared by every module on the machine. Ten thousand kernelets of a four-megabyte kind would want forty gigabytes of it. Loading the image ourselves costs a relocation loop and buys one physical copy of the text per kind, which is the whole point of the [previous page](one-address-space.md).

## Memory

A **grain** is 2 MiB of physically contiguous memory, and Linux's page allocator hands out physically contiguous blocks directly, up to a maximum of 4 MiB. A grain is one such allocation. Runs larger than that need the contiguous allocator Linux uses for huge pages, which is **not exported to modules**, so either the endovisor is limited to runs of two grains or a second symbol must be exported. The allocation may also sleep while it reclaims, so it cannot be made from a context holding a spin lock, and it fails under fragmentation where the host's own allocator would not.

Addressing is the [previous page](one-address-space.md)'s answer. On Linux the base is the direct map's, so there is nothing to map per grain and no page-table entry for the endovisor to write — at the price of the fail-stop property that page describes, since every frame on the machine is then addressable from every kernelet.

What the endovisor must still do at each grant is the accounting: zero the grain before publishing it (register D55), write the owner array, extend the instance's metadata region to cover the new frames, append the run descriptor, and publish the new length. The metadata region is the one thing still mapped per instance, with `vmap()` over pages the endovisor allocates for it.

## Tasks

A kernelet's tasks are the host's tasks, as in Asterinas mode. Here they are **kernel threads**: `kthread_run()` for each, pinned to the virtual CPU's processor, at a priority the endovisor sets. The `spawn_task` hook becomes a thread creation; the worker of each virtual CPU is a kernel thread parked on a wait queue.

Two things carry over unchanged because Linux offers the same primitives under different names. Per-CPU data is `DEFINE_PER_CPU` and `this_cpu_ptr` instead of OSTD's `cpu_local!`. Running something on a chosen processor is `smp_call_function_single` instead of an inter-processor interrupt the host sends itself.

One thing does not carry over: a kernel thread can never return to user mode. That is the subject of the [next page](tenant.md), and it is the hardest part of Linux mode.

## Interrupts and time

A kernelet has no interrupts of its own; the host raises a virtual line and the kernelet's worker runs the handler ([Interrupts and time](../design/virtualizing-ostd/interrupts-and-time.md)). On Linux this is a wakeup: `raise_irq` sets the line's pending bit and wakes the worker thread. Nothing traps, nothing is injected, and no interrupt controller is involved.

Deferred device work belongs in a **workqueue**, whose items run in a kernel thread and may sleep, or in a threaded interrupt handler where the device is real. Linux's older `tasklet` mechanism is deprecated and this design does not use it.

Time comes from the host as it does in Asterinas mode: the endovisor publishes a clock page the kernelet reads, and arms deadlines with Linux's high-resolution timers on the kernelet's behalf.

## Devices

The device models of the [Devices](../design/virtualizing-ostd/devices.md) page are host code either way. On Linux they sit in the module and reach real hardware through Linux's own subsystems: a block device through the block layer, a network device through a tap interface or a real one, a channel through the endovisor's own switch.

The [zero-copy design](../design/zero-copy-io.md) carries over in shape and not in all of its detail. Its lending rings, its validation, its lend count and its polling bit are all host-side code that Linux mode implements the same way. What differs is the bottom: that page assumes the host's block and network drivers gain a non-sleeping submission path, which is a change to *our* host. On Linux the equivalent is to submit through the block layer's existing asynchronous interface, which already exists and already does not sleep. Whether the rest of the argument survives that substitution is not settled here, and the [what differs](what-differs.md) page marks it.

## What a tenant sees

The same sandbox: a full Linux user space served by a kernelet. Nothing on this page is visible to it. What *is* visible to the operator is that the machine is running their own kernel, with one module loaded, three symbols exported, and — if they take the system-call patch that [the next page](tenant.md) argues for — about twenty-five lines changed in the entry path.
