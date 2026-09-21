# Tasks, scheduling, and CPUs

*How a kernelet's tasks become Linux tasks, where they come from, which stack they run on, and what "a CPU" means to a kernel that Linux schedules. It discharges the CPU half of fairness, and the rule that per-CPU data is never touched by two tasks at once.*

## What a kernelet task needs

The kernel proper creates tasks through OSTD's `TaskOptions::new(closure).build()` and starts them with `Task::run()`. Some are kernel threads that never leave the kernel. Some are tenant threads, whose closure is the loop on the [User mode](user-mode.md) page. OSTD's API does not say which is which when the task is created: a task becomes a tenant thread only when its closure first calls `UserMode::execute`.

So whatever carries a kernelet task on Linux must be schedulable by Linux, must keep a stack alive while the task sleeps or runs user code, and must be *able* to enter user mode even if it never does.

## Carriers {#carriers}

A **carrier** is the Linux task that carries one kernelet task. The pairing is one to one and lasts for the life of the task. Linux schedules carriers like any other task; the kernel proper's own scheduler is compiled in and never consulted, exactly as when Asterinas is the host. Waiting and waking map onto Linux directly: the services `task_park` and `task_unpark` are a sleep on, and a wake of, the carrier.

A carrier is *not* a Linux kernel thread. A kernel thread has no address space and can never return to user mode, and because OSTD does not announce which tasks will want to, every carrier has to be capable of it. Linux has exactly one kind of task with that property that kernel code can start in an in-kernel function: the kind Linux itself uses to launch `init` and its user-mode helpers, created by [`kernel_clone()`](https://elixir.bootlin.com/linux/v6.12/source/kernel/fork.c#L2745) with a start function and without the kernel-thread flag ([`user_mode_thread()`](https://elixir.bootlin.com/linux/v6.12/source/kernel/fork.c#L2854) is the in-tree caller). Such a task runs the function in kernel mode, and when the function returns, Linux's fork-return path takes the task to user mode with whatever is in its saved register file ([`ret_from_fork()`](https://elixir.bootlin.com/linux/v6.12/source/arch/x86/kernel/process.c#L140)). `kernel_clone()` is not exported to modules; the patch exports it, and that is the only thing the patch adds for this page.

## The root carrier, and the family it starts {#root}

<figure class="fwd-fig">
<div class="head">
<div class="tag">Where carriers come from</div>
<div class="title">A sandbox is one Linux process tree, cloned from a blank template</div>
</div>
<svg viewBox="0 0 900 330" role="img" aria-label="The kernelet runtime, a host user-space program, places a process in the sandbox's control group with its seccomp filter and credentials, and that process executes the sandbox file. The endovisor's binary-format handler gives it a blank address space and it becomes the root carrier, which never runs tenant code. Every kernelet task, the boot task, kernel threads, the interrupt worker, and each tenant thread, is carried by a clone of the root carrier made with kernel_clone, and each inherits the gate attachment, the seccomp filter, the control group, the credentials, a blank address space and a reference on the endovisor module.">
<defs>
<linearGradient id="tk-cg" x1="0" y1="0" x2="1" y2="0">
<stop offset="0%" stop-color="#00F7FF" stop-opacity=".22"/>
<stop offset="100%" stop-color="#1937FF" stop-opacity=".22"/>
</linearGradient>
<marker id="tk-a" viewBox="0 0 8 8" refX="7" refY="4" markerWidth="7" markerHeight="7" orient="auto-start-reverse">
<path d="M0 0 L8 4 L0 8 z" fill="#9AA0BE"/>
</marker>
<marker id="tk-ac" viewBox="0 0 8 8" refX="7" refY="4" markerWidth="7" markerHeight="7" orient="auto-start-reverse">
<path d="M0 0 L8 4 L0 8 z" fill="#00F7FF"/>
</marker>
</defs>
<g font-family="ui-monospace,monospace" font-size="10.5">
<rect x="20" y="20" width="250" height="64" rx="6" fill="rgba(255,255,255,.06)" stroke="rgba(255,255,255,.16)"/>
<text x="145" y="42" fill="#C9CCE0" text-anchor="middle">kernelet runtime</text>
<text x="145" y="58" fill="#6A6F8C" text-anchor="middle" font-size="8.5">sets cgroup &#183; seccomp filter &#183; credentials</text>
<text x="145" y="72" fill="#6A6F8C" text-anchor="middle" font-size="8.5">then: execve("sandbox.klet")</text>
<path d="M270 52 H330" stroke="#9AA0BE" stroke-width="1.4" marker-end="url(#tk-a)"/>
<rect x="332" y="20" width="250" height="64" rx="6" fill="rgba(25,55,255,.22)" stroke="rgba(0,247,255,.5)"/>
<text x="457" y="42" fill="#00F7FF" text-anchor="middle">endovisor: program loader</text>
<text x="457" y="58" fill="#5C93A8" text-anchor="middle" font-size="8.5">recognizes the file &#183; blank address space</text>
<text x="457" y="72" fill="#5C93A8" text-anchor="middle" font-size="8.5">attaches the gate</text>
<path d="M582 52 H642" stroke="#00F7FF" stroke-width="1.4" marker-end="url(#tk-ac)"/>
<rect x="644" y="20" width="236" height="64" rx="6" fill="url(#tk-cg)" stroke="rgba(0,247,255,.55)"/>
<text x="762" y="42" fill="#8FF6FC" text-anchor="middle">root carrier</text>
<text x="762" y="58" fill="#5C93A8" text-anchor="middle" font-size="8.5">never runs tenant code</text>
<text x="762" y="72" fill="#5C93A8" text-anchor="middle" font-size="8.5">loop: take request &#183; kernel_clone()</text>
<path d="M762 84 V128" stroke="#00F7FF" stroke-width="1.4"/>
<path d="M110 128 H762" stroke="#00F7FF" stroke-width="1.4"/>
<path d="M110 128 V158" stroke="#00F7FF" stroke-width="1.4" marker-end="url(#tk-ac)"/>
<path d="M327 128 V158" stroke="#00F7FF" stroke-width="1.4" marker-end="url(#tk-ac)"/>
<path d="M544 128 V158" stroke="#00F7FF" stroke-width="1.4" marker-end="url(#tk-ac)"/>
<path d="M762 128 V158" stroke="#00F7FF" stroke-width="1.4" marker-end="url(#tk-ac)"/>
<text x="436" y="120" fill="#00F7FF" text-anchor="middle" font-size="9">one clone per kernelet task, started in an in-kernel function</text>
<g>
<rect x="20" y="160" width="180" height="70" rx="6" fill="url(#tk-cg)" stroke="rgba(0,247,255,.55)"/>
<text x="110" y="182" fill="#8FF6FC" text-anchor="middle">carrier</text>
<text x="110" y="200" fill="#C9CCE0" text-anchor="middle" font-size="9.5">boot task</text>
<text x="110" y="216" fill="#5C93A8" text-anchor="middle" font-size="8.5">stays in kernel mode</text>
<rect x="237" y="160" width="180" height="70" rx="6" fill="url(#tk-cg)" stroke="rgba(0,247,255,.55)"/>
<text x="327" y="182" fill="#8FF6FC" text-anchor="middle">carrier</text>
<text x="327" y="200" fill="#C9CCE0" text-anchor="middle" font-size="9.5">kernel thread / worker</text>
<text x="327" y="216" fill="#5C93A8" text-anchor="middle" font-size="8.5">stays in kernel mode</text>
<rect x="454" y="160" width="180" height="70" rx="6" fill="url(#tk-cg)" stroke="rgba(0,247,255,.55)"/>
<text x="544" y="182" fill="#8FF6FC" text-anchor="middle">carrier</text>
<text x="544" y="200" fill="#C9CCE0" text-anchor="middle" font-size="9.5">tenant thread A</text>
<text x="544" y="216" fill="#5C93A8" text-anchor="middle" font-size="8.5">enters user mode</text>
<rect x="672" y="160" width="180" height="70" rx="6" fill="url(#tk-cg)" stroke="rgba(0,247,255,.55)"/>
<text x="762" y="182" fill="#8FF6FC" text-anchor="middle">carrier</text>
<text x="762" y="200" fill="#C9CCE0" text-anchor="middle" font-size="9.5">tenant thread B</text>
<text x="762" y="216" fill="#5C93A8" text-anchor="middle" font-size="8.5">enters user mode</text>
</g>
<rect x="20" y="254" width="860" height="56" rx="8" fill="rgba(255,255,255,.025)" stroke="rgba(255,255,255,.12)"/>
<text x="36" y="274" fill="#9A9DB0" font-size="9" letter-spacing="1.4">INHERITED BY EVERY CLONE, BECAUSE LINUX COPIES IT</text>
<text x="36" y="294" fill="#C9CCE0" font-size="9.5">gate attachment &#183; seccomp filter &#183; control group &#183; credentials &#183; namespaces &#183; blank address space (no vDSO) &#183; module reference</text>
</g>
</svg>
<figcaption>Nothing in the bottom row is set up per carrier by the endovisor. It is what <code>fork</code> does, which is why there is no window in which a carrier lacks it.</figcaption>
</figure>

A sandbox begins as an ordinary process that the [kernelet runtime](../kernelet-runtime.md) has prepared: it has been placed in the sandbox's control group, given the sandbox's credentials and namespaces, and has installed the seccomp filter from the [User mode](user-mode.md) page. That process then executes the **sandbox file**, a small in-memory file that the endovisor made for this sandbox and handed to the runtime as a descriptor ([The endovisor](../endovisor.md#abi)), as if it were a program.

Linux lets a module teach it new executable formats: a **binary-format handler** ([`struct linux_binfmt`](https://elixir.bootlin.com/linux/v6.12/source/include/linux/binfmts.h#L82), registered with [`__register_binfmt()`](https://elixir.bootlin.com/linux/v6.12/source/fs/exec.c#L88)) is offered every file that is executed and may claim it. The endovisor registers one that claims sandbox files. Its handler does what every program loader does first, calling [`begin_new_exec()`](https://elixir.bootlin.com/linux/v6.12/source/fs/exec.c#L1222), which gives the process a fresh address space, closes its close-on-exec descriptors and resets its signal handlers. It then makes the address space truly blank. Linux has already placed one area in it, the temporary stack that holds the arguments and environment of the `execve`, which the ELF loader would go on to use; this handler unmaps it, so that nothing of the host's is left for a tenant to read. It maps no program and no stack, and no vDSO, since mapping that page is the ELF loader's act and not Linux's. It initializes the process's saved registers as a 64-bit user task, which matters even though this process will never run user code: a clone that starts in a kernel function copies its parent's saved registers, segment selectors and flags included, so every carrier starts from whatever the root carrier has (*found by the prototype*). It attaches the gate to the process, [flags it](user-mode.md#gate), and returns. The process is now the **root carrier**.

The root carrier never reaches user mode. On its way there the gate's resume hook runs, and for the root carrier that hook is a service loop: wait for a request to start a kernelet task, discard any signal that is pending on itself other than `SIGKILL`, call `kernel_clone()` with the endovisor's start function, repeat. The middle step is not tidiness: `kernel_clone()` refuses to run for a caller with a signal pending, and a root carrier that never returns to user mode would otherwise never clear one. A clone that still fails for that reason is retried. The first request is for the kernelet's boot task. Each later one comes from the service `task_spawn`, which is what `Task::run()` becomes; the service queues the request and returns without waiting, so `run()` keeps OSTD's meaning of "make runnable".

Every carrier is thus a child of the root carrier, and a clone without shared memory: it gets its own copy of the root's blank address space, which stays empty unless the task enters user mode ([Memory](memory.md#cache)). What it inherits is the row at the bottom of the figure. Two of those entries deserve a sentence each. The *module reference* is Linux's own: an address space created by a binary-format handler holds a reference on the handler's module, a forked copy takes another ([`dup_mm()`](https://elixir.bootlin.com/linux/v6.12/source/kernel/fork.c#L1682)), and both are dropped by core kernel code when the address space dies ([`__mmput()`](https://elixir.bootlin.com/linux/v6.12/source/kernel/fork.c#L1340)), so the endovisor cannot be unloaded from under a carrier. One thing must be added by hand: the endovisor's file objects name the module as their owner, because Linux releases the last of them slightly *after* it drops the address space's reference (*found by the prototype*, as a crash in unloaded code). The *control group* is what makes fair accounting a matter of membership rather than bookkeeping: every task of the kernelet, kernel thread or tenant thread, is a member of the sandbox's group, so the processor time the kernelet burns and the kernel memory Linux allocates on its behalf are charged to the sandbox by the machinery Linux already has.

The root carrier sets `SIGCHLD` to *ignored*, which makes Linux reap its children without a wait.

## Kernelet stacks

A carrier's Linux kernel stack is 16 KiB ([`THREAD_SIZE_ORDER`](https://elixir.bootlin.com/linux/v6.12/source/arch/x86/include/asm/page_64_types.h#L15)), is shared with Linux's own entry frames, and is emptied on every return to user mode. A kernelet task needs a stack that is larger, since a full Linux-compatible system-call path in Rust runs on it, and that persists, since the task's loop lives on it. So each kernelet task has a **kernelet stack**: 256 KiB of Linux's `vmalloc` memory, which comes with an unmapped guard page on either side, allocated by the endovisor when the carrier starts and freed when it dies.

The rule is simple: **kernelet code runs on the kernelet stack, and Linux's and the endovisor's code runs on the Linux stack.** The carrier switches to the kernelet stack when a gate hook resumes the kernelet, and back when the kernelet calls `user_run`. It also switches to the Linux stack for the length of every [service call](../kernelet-api-service.md#depth), so that Linux's code, including every sleep, runs on a stack Linux knows. The switch is a dozen instructions that save the callee-saved registers and exchange the stack pointer. Linux tolerates kernelet code on a stack it did not allocate:

- The scheduler saves and restores only the stack pointer, so a carrier can be preempted on the kernelet stack.
- Linux finds the current task through a per-processor pointer, not through the stack.
- An interrupt that arrives on the kernelet stack pushes its frame there and then moves to Linux's per-processor interrupt stack, as it would on any kernel stack.
- The saved user registers are found from the top of the Linux stack, which does not move.

One thing Linux does not tolerate is an overflow. Running off the end of a kernelet stack hits the guard page while the stack pointer is already bad, which escalates to a double fault, and Linux halts the machine on a double fault whose stack it does not recognize ([`exc_double_fault`](https://elixir.bootlin.com/linux/v6.12/source/arch/x86/kernel/traps.c#L401)). Depth of recursion in the kernel proper can depend on tenant input, so this must not be left to chance. Kernelet images are compiled with a call at every function entry that compares the stack pointer with a limit in the carrier record and ends the kernelet in an orderly way when only a 16 KiB reserve remains; the mechanism is on the [Faults](../faults-and-reclamation.md#stack) page.

## Seats {#seats}

The kernel proper uses per-CPU data everywhere: allocator caches, statistics, the read side of RCU. OSTD's contract for it is that code which has disabled preemption has the current CPU's copy to itself. On bare metal that holds because a CPU runs one thing at a time.

Carriers break the premise twice. Linux migrates them between processors whenever it likes, in the middle of any computation. And Linux will happily run more carriers of one kernelet at the same instant than the kernelet has virtual CPUs, so two of them could pick the same copy. A preemption counter cannot fix the second problem, and on a Linux built without kernel preemption the first has no primitive to hook.

<figure class="fwd-fig">
<div class="head">
<div class="tag">Seats</div>
<div class="title">A virtual CPU is a lease on one copy of the per-CPU data, not a processor</div>
</div>
<svg viewBox="0 0 900 250" role="img" aria-label="A kernelet with two seats. Each seat is one copy of the kernelet's per-CPU data. Five carriers: carrier A holds seat 0 and carrier B holds seat 1, and both are running kernelet code, on whatever processors Linux chose. Carrier C is in user mode and holds no seat. Carrier D is asleep inside a service call and holds no seat. Carrier E has just made a system call and waits for a seat to come free.">
<defs>
<linearGradient id="st-cg" x1="0" y1="0" x2="1" y2="0">
<stop offset="0%" stop-color="#00F7FF" stop-opacity=".22"/>
<stop offset="100%" stop-color="#1937FF" stop-opacity=".22"/>
</linearGradient>
<marker id="st-ac" viewBox="0 0 8 8" refX="7" refY="4" markerWidth="7" markerHeight="7" orient="auto-start-reverse">
<path d="M0 0 L8 4 L0 8 z" fill="#00F7FF"/>
</marker>
</defs>
<g font-family="ui-monospace,monospace" font-size="10.5">
<text x="20" y="22" fill="#00F7FF" font-size="9" letter-spacing="1.4">THE KERNELET'S SEATS (2 VIRTUAL CPUS)</text>
<rect x="20" y="32" width="250" height="56" rx="6" fill="url(#st-cg)" stroke="rgba(0,247,255,.55)"/>
<text x="145" y="54" fill="#8FF6FC" text-anchor="middle">seat 0</text>
<text x="145" y="72" fill="#5C93A8" text-anchor="middle" font-size="8.5">per-CPU data, copy 0 &#183; held by A</text>
<rect x="290" y="32" width="250" height="56" rx="6" fill="url(#st-cg)" stroke="rgba(0,247,255,.55)"/>
<text x="415" y="54" fill="#8FF6FC" text-anchor="middle">seat 1</text>
<text x="415" y="72" fill="#5C93A8" text-anchor="middle" font-size="8.5">per-CPU data, copy 1 &#183; held by B</text>
<text x="20" y="130" fill="#9A9DB0" font-size="9" letter-spacing="1.4">ITS CARRIERS, WHEREVER LINUX RUNS THEM</text>
<g>
<rect x="20" y="140" width="160" height="64" rx="6" fill="rgba(25,55,255,.22)" stroke="rgba(0,247,255,.5)"/>
<text x="100" y="162" fill="#00F7FF" text-anchor="middle">carrier A</text>
<text x="100" y="178" fill="#C9CCE0" text-anchor="middle" font-size="9">in kernelet code</text>
<text x="100" y="193" fill="#5C93A8" text-anchor="middle" font-size="8.5">holds seat 0</text>
<rect x="195" y="140" width="160" height="64" rx="6" fill="rgba(25,55,255,.22)" stroke="rgba(0,247,255,.5)"/>
<text x="275" y="162" fill="#00F7FF" text-anchor="middle">carrier B</text>
<text x="275" y="178" fill="#C9CCE0" text-anchor="middle" font-size="9">in kernelet code</text>
<text x="275" y="193" fill="#5C93A8" text-anchor="middle" font-size="8.5">holds seat 1</text>
<rect x="370" y="140" width="160" height="64" rx="6" fill="rgba(255,255,255,.06)" stroke="rgba(255,255,255,.16)"/>
<text x="450" y="162" fill="#C9CCE0" text-anchor="middle">carrier C</text>
<text x="450" y="178" fill="#9AA0BE" text-anchor="middle" font-size="9">in user mode</text>
<text x="450" y="193" fill="#6A6F8C" text-anchor="middle" font-size="8.5">no seat</text>
<rect x="545" y="140" width="160" height="64" rx="6" fill="rgba(255,255,255,.06)" stroke="rgba(255,255,255,.16)"/>
<text x="625" y="162" fill="#C9CCE0" text-anchor="middle">carrier D</text>
<text x="625" y="178" fill="#9AA0BE" text-anchor="middle" font-size="9">asleep in task_park</text>
<text x="625" y="193" fill="#6A6F8C" text-anchor="middle" font-size="8.5">gave its seat up</text>
<rect x="720" y="140" width="160" height="64" rx="6" fill="rgba(255,255,255,.03)" stroke="rgba(0,247,255,.35)" stroke-dasharray="4 3"/>
<text x="800" y="162" fill="#C9CCE0" text-anchor="middle">carrier E</text>
<text x="800" y="178" fill="#9AA0BE" text-anchor="middle" font-size="9">just made a system call</text>
<text x="800" y="193" fill="#00F7FF" text-anchor="middle" font-size="8.5">waits for a free seat</text>
</g>
<path d="M100 140 V92" stroke="#00F7FF" stroke-width="1.4" marker-end="url(#st-ac)"/>
<path d="M275 140 Q300 110 380 92" stroke="#00F7FF" stroke-width="1.4" fill="none" marker-end="url(#st-ac)"/>
<text x="560" y="56" fill="#9AA0BE" font-size="9">taken on entering kernelet code</text>
<text x="560" y="72" fill="#9AA0BE" font-size="9">given up on leaving: to user mode, or to sleep</text>
<text x="450" y="232" fill="#6A6F8C" text-anchor="middle" font-size="9">Linux may run all five at once, on any processors. At most two of them are ever inside the kernelet.</text>
</g>
</svg>
</figure>

The kernel proper does not care which processor it is on. It cares that nobody else is touching its copy. A **seat** makes that the definition: a seat is a lease on one copy of the kernelet's per-CPU data, and a kernelet has as many seats as it has virtual CPUs. A carrier takes a free seat whenever it enters kernelet code (from the gate, or on waking inside a service call) and gives it up whenever it leaves (to user mode, or to sleep). While it holds a seat, `CpuId::current()` is the seat's number and the per-CPU accessors index that seat's copy. Race freedom comes from possession, so it does not depend on how Linux was configured, and a carrier that Linux preempts or migrates while holding a seat simply keeps it.

A task may be restricted to some seats (`task_spawn` and `task_set_seats` carry a mask), and then waits for one of those. That is how OSTD's "run this on CPU *i*" is honored: each virtual CPU's [worker](interrupts-and-time.md), for instance, is restricted to its own seat, so that timers and interrupt handlers for virtual CPU *i* always see virtual CPU *i*'s data.

If every permitted seat is taken, the carrier sleeps until one is free. That caps a tenant's parallelism *inside its kernel* at its virtual-CPU count, which is what a virtual-CPU count means, and it is something a tenant can observe as latency when it is oversubscribed.

A seat is never taken away from a carrier that holds it. So a carrier that stays in kernelet code for a long time keeps its virtual CPU's worker waiting, and with it that virtual CPU's timers and interrupt handlers, where on a machine an interrupt would simply have landed. The tenant whose kernel does this delays only its own I/O, and [eviction](../faults-and-reclamation.md#eviction) bounds the pathological case.

A seat is also where per-virtual-CPU bookkeeping lives: the RCU state (a seat nobody holds is quiescent by definition, so an idle virtual CPU never stalls a grace period), and an optional processor-time budget that can refuse a seat to a kernelet that has exhausted its quota.

## Priority, affinity, and preemption

OSTD lets the kernel proper set a task's priority and CPU affinity. The `task_spawn` request carries both, and the root carrier applies them to the clone with [`set_user_nice()`](https://elixir.bootlin.com/linux/v6.12/source/kernel/sched/syscalls.c#L65) and [`set_cpus_allowed_ptr()`](https://elixir.bootlin.com/linux/v6.12/source/kernel/sched/core.c#L3118), both exported, after intersecting the affinity with the processors the sandbox is allowed. Hard limits on processor time come from the sandbox's control group.

Linux preempts kernelet code like any other kernel code, if it was built to preempt at all. `disable_preempt()` in vOSTD therefore does not talk to Linux. It raises a per-task **no-preemption counter**, kept in vOSTD, which means three things inside the kernelet and nothing outside it. While it is raised the task keeps its seat, so nobody else touches its per-CPU data. vOSTD will not make a service call that gives up the seat (the service half refuses one with an error, as a check on the kernel proper's own discipline). And it stands in for "interrupts off", which is sound because no kernelet code ever runs in interrupt context. That is all the kernel proper's uses of it need.

## When a task ends, and when a carrier dies {#death}

When a kernelet task's closure returns, the carrier switches to its Linux stack for the last time, detaches itself from the gate, frees the kernelet stack, and ends by sending itself `SIGKILL`; Linux offers a module no direct way to exit a task that is not a kernel thread. Because no two carriers share a Linux thread group, the signal ends that one task.

A carrier can also be killed from outside, by the operator or by Linux's out-of-memory killer. Killing *one* carrier would abandon a kernelet task in the middle of whatever it was doing, possibly holding the kernel proper's locks, and the kernelet as a whole cannot survive that. So the unit of killing is the sandbox. Every carrier holds, from the moment it starts, one open file of the endovisor's in its Linux descriptor table, its **lifeline**. Nothing reads or writes it. (A clone begins with a copy of its parent's descriptor table. The root carrier's table holds exactly one descriptor, its own lifeline, because the program loader closes every other descriptor the runtime's child still had; a new carrier's start function closes the inherited copy before it opens its own, so that each lifeline has exactly one holder.) Linux closes a task's descriptors when the task exits, whatever the cause, and the file's release function is the endovisor's notice that the carrier is gone; if the carrier had not [left for good](../faults-and-reclamation.md#leaving) by then, the endovisor ends the whole kernelet. A tenant cannot close its lifeline, because closing a descriptor is a Linux system call.

A carrier is an ordinary Linux task, so the host can send it other signals too. The gate's [resume hook](user-mode.md#exceptions) discards every one but `SIGKILL`: a carrier cannot be stopped, continued or terminated politely, one at a time, from the host. To end a sandbox the operator uses `KERNELET_KILL` or the group's `cgroup.kill`. *Pausing* one with the control group's freezer is not supported: Linux freezes a group's tasks as they pass through its signal-delivery code, which a carrier that stays in the kernel (the root carrier, a worker, a parked task) never reaches, and while a freeze is pending Linux refuses the root carrier's clones. The runtime therefore does not offer the container interface's `pause`. Inside the sandbox, of course, the tenant kills its own processes as often as it likes; those are the kernel proper's signals, and Linux never hears of them.

## Costs

- **Per kernelet task**: a Linux task structure, a 16 KiB Linux stack that is mostly idle, a 256 KiB kernelet stack, and an address-space descriptor with one top-level page table, about 10 KiB (*estimated* from structure sizes), even for tasks that never enter user mode. That last item is the price of not knowing in advance which tasks will.
- **Per task creation**: one queue operation and a wake of the root carrier on the creator's side; one `kernel_clone()` of an empty address space on the root's side. **[unverified]**: tens of microseconds, not measured on its own.
- **Per entry into kernelet code**: a seat acquire and release, two uncontended atomic operations.

## What a tenant sees

The same processes and threads, scheduled by Linux's scheduler instead of Asterinas's, with `nice` and affinity honored. A tenant with more runnable threads in the kernel than virtual CPUs sees them queue for seats. Every thread of the sandbox, including the kernelet's own kernel threads, appears to the *host's* tools as a process in the sandbox's control group; none of that is visible from inside.

## What this page decides

- **Every kernelet task is carried by a Linux task cloned from the sandbox's root carrier with `kernel_clone()`** (register D93). Alternatives: kernel threads, which cannot enter user mode; letting Linux service the tenant's own `clone` call, which would require the kernel proper to know about it and so break the rule that its source does not change; and Linux's user-mode-helper interface, which needs no export but starts every task in the wrong control group, with the wrong credentials and without the filter.
- **The root carrier is created by a binary-format handler** (register D94), because `exec` is the one operation that gives a process a blank address space, and because Linux's own reference counting then pins the module for exactly as long as any carrier's address space lives.
- **Kernelet code runs on a per-task kernelet stack** (register D84, kept). Linux's own stack is too small and does not persist.
- **Per-CPU data is selected by a seat** (register D88, kept). Deriving the virtual CPU from the processor is unsound when Linux runs more carriers than virtual CPUs, and pinning rests on preemption settings the operator owns.
