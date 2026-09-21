# Virtualizing OSTD

*The middle of the design: for each part of OSTD's interface that the kernel proper uses, what it becomes inside a kernelet on Linux. This page gives the classification and the whole map on one table; the six pages below it give the mechanisms.*

## Three kinds of item

The kernel proper is written against OSTD's public interface: a few hundred types, functions and macros. vOSTD offers the same interface, and sorts every item into one of three kinds.

- **Identical.** The item's code is the same in vOSTD as in OSTD, because its effect is local to the kernelet: a spin lock, a reference-counted frame handle, a page-table walk over the kernelet's own tables, the unwinder.
- **Virtualized.** The item keeps its name and signature and has a different body. Some virtualized items never leave the kernelet (reading per-CPU data, reading the clock page). The others call the **service table**, the fixed set of host functions a kernelet is handed when it starts ([service half](../kernelet-api-service.md)).
- **Absent.** The item does not exist in vOSTD, so a use of it fails to compile. Every absent item is something a tenant's kernel must never have: port I/O, the interrupt controller, the IOMMU, sending inter-processor interrupts.

The sorting is a property of the kernelet build, and it is the same whichever kernel is the host. The item-by-item classification has 72 rows (*counted*): 26 identical, 38 virtualized, 7 absent, and one that is internal to OSTD; 22 of the virtualized ones never call the host at all. Because it does not depend on the host, the book keeps that long table in one place, [with the Asterinas host](../../design/virtualizing-ostd/index.md). Nothing in this chapter depends on reading it: the figure below covers every module of OSTD's interface, and each mechanism page names the items it virtualizes.

What the host changes is **what stands behind the service table**, and, in three places, a body inside vOSTD itself. vOSTD is compiled per host, from one source, with a build-time switch that selects:

1. how vOSTD finds the record of the task it is running on (through Linux's current-task pointer, rather than a slot the Asterinas host maintains);
2. how the fallible copy routines reach tenant memory ([by walking the model](memory.md#copies), rather than by dereferencing the tenant's address);
3. the function-entry [stack check](../faults-and-reclamation.md#stack), which only Linux needs.

The kernel proper is compiled from identical source on both.

## The whole map

<figure class="fwd-fig">
<div class="head">
<div class="tag">One interface, a different machine underneath</div>
<div class="title">What each part of OSTD becomes on Linux</div>
</div>
<svg viewBox="0 0 900 392" role="img" aria-label="Three columns. Left: what the kernel proper uses, unchanged: Task and TaskOptions; WaitQueue and Mutex; UserMode execute; VmSpace and its cursors; VmReader and VmWriter; FrameAllocOptions; IrqLine and timers; IoMem; per-CPU data; println and poweroff. Middle: what vOSTD does: asks for a task by service call; parks and unparks by service call; calls user_run; keeps a page table as a model; walks the model and copies through the direct map; allocates from the grant; runs handlers on a worker task; makes one service call per register access; indexes by seat; calls log_write and stop. Right: what Linux provides: a carrier cloned from the root carrier; sleep and wake of that task; the gate in the entry path; a memory area whose fault handler fills Linux's page table from the model; nothing at all for copies; pages from the page allocator, charged to the sandbox's control group; wakeups and high-resolution timers; device models over files and sockets; nothing at all for per-CPU data; a log ring and the end of the sandbox.">
<defs>
<linearGradient id="vo-cg" x1="0" y1="0" x2="1" y2="0">
<stop offset="0%" stop-color="#00F7FF" stop-opacity=".22"/>
<stop offset="100%" stop-color="#1937FF" stop-opacity=".22"/>
</linearGradient>
</defs>
<g font-family="ui-monospace,monospace" font-size="9.5">
<text x="20" y="20" fill="#8FF6FC" font-size="9" letter-spacing="1.4">THE KERNEL PROPER USES (UNCHANGED)</text>
<text x="318" y="20" fill="#00F7FF" font-size="9" letter-spacing="1.4">vOSTD DOES</text>
<text x="612" y="20" fill="#9A9DB0" font-size="9" letter-spacing="1.4">LINUX PROVIDES</text>
<g fill="url(#vo-cg)" stroke="rgba(0,247,255,.55)">
<rect x="20" y="30" width="270" height="30" rx="5"/><rect x="20" y="66" width="270" height="30" rx="5"/><rect x="20" y="102" width="270" height="30" rx="5"/><rect x="20" y="138" width="270" height="30" rx="5"/><rect x="20" y="174" width="270" height="30" rx="5"/><rect x="20" y="210" width="270" height="30" rx="5"/><rect x="20" y="246" width="270" height="30" rx="5"/><rect x="20" y="282" width="270" height="30" rx="5"/><rect x="20" y="318" width="270" height="30" rx="5"/><rect x="20" y="354" width="270" height="30" rx="5"/>
</g>
<g fill="rgba(25,55,255,.22)" stroke="rgba(0,247,255,.5)">
<rect x="314" y="30" width="270" height="30" rx="5"/><rect x="314" y="66" width="270" height="30" rx="5"/><rect x="314" y="102" width="270" height="30" rx="5"/><rect x="314" y="138" width="270" height="30" rx="5"/><rect x="314" y="174" width="270" height="30" rx="5"/><rect x="314" y="210" width="270" height="30" rx="5"/><rect x="314" y="246" width="270" height="30" rx="5"/><rect x="314" y="282" width="270" height="30" rx="5"/><rect x="314" y="318" width="270" height="30" rx="5"/><rect x="314" y="354" width="270" height="30" rx="5"/>
</g>
<g fill="rgba(255,255,255,.06)" stroke="rgba(255,255,255,.16)">
<rect x="608" y="30" width="272" height="30" rx="5"/><rect x="608" y="66" width="272" height="30" rx="5"/><rect x="608" y="102" width="272" height="30" rx="5"/><rect x="608" y="138" width="272" height="30" rx="5"/><rect x="608" y="210" width="272" height="30" rx="5"/><rect x="608" y="246" width="272" height="30" rx="5"/><rect x="608" y="282" width="272" height="30" rx="5"/><rect x="608" y="354" width="272" height="30" rx="5"/>
</g>
<g fill="rgba(255,255,255,.02)" stroke="rgba(255,255,255,.10)" stroke-dasharray="4 3">
<rect x="608" y="174" width="272" height="30" rx="5"/><rect x="608" y="318" width="272" height="30" rx="5"/>
</g>
<g fill="#C9CCE0">
<text x="32" y="49">Task, TaskOptions</text><text x="32" y="85">WaitQueue, Mutex</text><text x="32" y="121">UserMode::execute</text><text x="32" y="157">VmSpace, cursors, TlbFlusher</text><text x="32" y="193">VmReader, VmWriter (tenant memory)</text><text x="32" y="229">FrameAllocOptions, Frame, Segment</text><text x="32" y="265">IrqLine, timers, Jiffies</text><text x="32" y="301">IoMem (device registers)</text><text x="32" y="337">cpu_local!, disable_preempt</text><text x="32" y="373">println!, power::poweroff</text>
</g>
<g fill="#8FF6FC">
<text x="326" y="49">task_spawn service</text><text x="326" y="85">task_park / task_unpark services</text><text x="326" y="121">user_run service</text><text x="326" y="157">keeps a page table: the model</text><text x="326" y="193">walks the model, uses the direct map</text><text x="326" y="229">own allocator over the grant</text><text x="326" y="265">handlers run on a worker task</text><text x="326" y="301">one service call per access</text><text x="326" y="337">indexes by seat; a counter</text><text x="326" y="373">log_write, stop services</text>
</g>
<g fill="#9AA0BE">
<text x="620" y="49">a carrier cloned from the root carrier</text><text x="620" y="85">sleep and wake of the carrier</text><text x="620" y="121">the gate in the entry path</text><text x="620" y="157">its page table as a cache, by fault</text><text x="620" y="229">page allocator, charged by cgroup</text><text x="620" y="265">task wakeups, hrtimers</text><text x="620" y="301">models over files and sockets</text><text x="620" y="373">a log ring; the end of the sandbox</text>
</g>
<g fill="#6A6F8C">
<text x="620" y="193">nothing: Linux is not involved</text><text x="620" y="337">nothing: Linux is not involved</text>
</g>
<g stroke="rgba(0,247,255,.45)" stroke-width="1">
<path d="M290 45 H314 M290 81 H314 M290 117 H314 M290 153 H314 M290 189 H314 M290 225 H314 M290 261 H314 M290 297 H314 M290 333 H314 M290 369 H314"/>
<path d="M584 45 H608 M584 81 H608 M584 117 H608 M584 153 H608 M584 225 H608 M584 261 H608 M584 297 H608 M584 369 H608"/>
</g>
</g>
</svg>
</figure>

## In this section

- [Memory](memory.md): grains from Linux's page allocator; the kernelet's page table as a model and Linux's as a cache of it; reaching tenant memory without dereferencing it.
- [Tasks, scheduling, and CPUs](tasks.md): carriers, the root carrier, kernelet stacks, and seats.
- [Interrupts and time](interrupts-and-time.md): virtual interrupt lines, workers and jobs, the clock page and deadlines.
- [User mode](user-mode.md): the gate, `user_run`, exceptions, and what a tenant can never reach.
- [Devices](devices.md): virtio over function calls, and device models over Linux's files and sockets.
- [Boot, power, panic, and the rest](the-rest.md): entry, exit, the log, panics, and the machine a kernelet can still touch.
