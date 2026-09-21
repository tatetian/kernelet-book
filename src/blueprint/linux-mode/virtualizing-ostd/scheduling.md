# Scheduling

*How a kernelet's own scheduler decides which of its tasks run, while Linux decides only how much processor the sandbox gets. This page replaces the earlier rule that a kernelet's scheduler is inert. It discharges the processor half of fairness, and it is where the design meets the oldest problem of running one scheduler on top of another.*

## Two schedulers, and who decides what

The kernel proper contains a complete scheduler: run queues per CPU, priorities and `nice` values, real-time classes, time slices, load balancing. OSTD lets a kernel supply one with `inject_scheduler`, and calls it to *enqueue* a task that became runnable, to *pick the next* task for a CPU, and to *update* the running task's accounting on every timer tick.

There are two ways to honor that scheduler inside a sandbox, and they differ in who has the last word.

In the first, every kernelet task is a task of the host, and the host's scheduler runs them all. The kernelet's scheduler is compiled in and never asked. That is simple, and it is what this chapter specified until now. Its price is that a tenant gets the *host's* idea of scheduling: a tenant's real-time thread is not real-time, its `nice` values mean what Linux's fair class says they mean among however many other threads it has, and the kernel proper's carefully written policy is dead code.

In the second, there are **two levels**. Linux schedules *virtual CPUs*, a handful per sandbox, and knows nothing else about the sandbox. On each virtual CPU, the kernelet's own scheduler decides which kernelet task runs, for how long, and what preempts what. This page specifies the second.

<figure class="fwd-fig">
<div class="head">
<div class="tag">Two levels</div>
<div class="title">Linux decides how much processor a sandbox gets; the kernelet decides who inside it runs</div>
</div>
<svg viewBox="0 0 900 360" role="img" aria-label="Two levels of scheduling. At the bottom, Linux's scheduler shares four processors among the control groups of the machine by weight and limit: sandbox A, sandbox B, and the host's own workloads. Each sandbox appears to Linux as a small fixed number of Linux tasks, its virtual CPU carriers: two for sandbox A, however many tasks run inside. At the top, inside sandbox A, the kernelet's own scheduler keeps a run queue per virtual CPU holding many kernelet tasks, tenant threads and kernel threads, and picks which one runs on each virtual CPU, by its own priorities and time slices. Linux never sees those tasks.">
<defs>
<linearGradient id="sc-cg" x1="0" y1="0" x2="1" y2="0">
<stop offset="0%" stop-color="#00F7FF" stop-opacity=".22"/>
<stop offset="100%" stop-color="#1937FF" stop-opacity=".22"/>
</linearGradient>
<marker id="sc-ac" viewBox="0 0 8 8" refX="7" refY="4" markerWidth="7" markerHeight="7" orient="auto-start-reverse">
<path d="M0 0 L8 4 L0 8 z" fill="#00F7FF"/>
</marker>
<marker id="sc-a" viewBox="0 0 8 8" refX="7" refY="4" markerWidth="7" markerHeight="7" orient="auto-start-reverse">
<path d="M0 0 L8 4 L0 8 z" fill="#9AA0BE"/>
</marker>
</defs>
<g font-family="ui-monospace,monospace" font-size="10">
<rect x="20" y="16" width="560" height="176" rx="10" fill="rgba(0,247,255,.04)" stroke="rgba(0,247,255,.42)"/>
<text x="32" y="34" fill="#00F7FF" font-size="9" letter-spacing="1.4">LEVEL 2 &#183; INSIDE SANDBOX A &#183; THE KERNELET'S OWN SCHEDULER</text>
<rect x="36" y="46" width="256" height="92" rx="6" fill="url(#sc-cg)" stroke="rgba(0,247,255,.55)"/>
<text x="48" y="64" fill="#8FF6FC">run queue of virtual CPU 0</text>
<g fill="rgba(6,10,36,.55)" stroke="rgba(0,247,255,.35)">
<rect x="48" y="74" width="54" height="22" rx="4"/><rect x="108" y="74" width="54" height="22" rx="4"/><rect x="168" y="74" width="54" height="22" rx="4"/><rect x="228" y="74" width="54" height="22" rx="4"/>
<rect x="48" y="104" width="54" height="22" rx="4"/><rect x="108" y="104" width="54" height="22" rx="4"/>
</g>
<g fill="#C9CCE0" font-size="8.5" text-anchor="middle">
<text x="75" y="89">rt 50</text><text x="135" y="89">nice 0</text><text x="195" y="89">nice 0</text><text x="255" y="89">nice 10</text><text x="75" y="119">kthread</text><text x="135" y="119">nice 19</text>
</g>
<rect x="308" y="46" width="256" height="92" rx="6" fill="url(#sc-cg)" stroke="rgba(0,247,255,.55)"/>
<text x="320" y="64" fill="#8FF6FC">run queue of virtual CPU 1</text>
<g fill="rgba(6,10,36,.55)" stroke="rgba(0,247,255,.35)">
<rect x="320" y="74" width="54" height="22" rx="4"/><rect x="380" y="74" width="54" height="22" rx="4"/><rect x="440" y="74" width="54" height="22" rx="4"/>
</g>
<g fill="#C9CCE0" font-size="8.5" text-anchor="middle">
<text x="347" y="89">nice -5</text><text x="407" y="89">nice 0</text><text x="467" y="89">kthread</text>
</g>
<text x="164" y="160" fill="#5C93A8" text-anchor="middle" font-size="8.5">picks one: by ITS priorities, slices, preemption</text>
<text x="436" y="160" fill="#5C93A8" text-anchor="middle" font-size="8.5">picks one</text>
<path d="M164 166 V212" stroke="#00F7FF" stroke-width="1.4" marker-end="url(#sc-ac)"/>
<path d="M436 166 V212" stroke="#00F7FF" stroke-width="1.4" marker-end="url(#sc-ac)"/>
<text x="300" y="184" fill="#6A6F8C" text-anchor="middle" font-size="8.5">Linux never sees these tasks</text>
<rect x="600" y="16" width="130" height="176" rx="10" fill="rgba(0,247,255,.04)" stroke="rgba(0,247,255,.30)"/>
<text x="665" y="34" fill="#5C93A8" font-size="9" text-anchor="middle" letter-spacing="1.2">SANDBOX B</text>
<text x="665" y="104" fill="#6A6F8C" text-anchor="middle" font-size="8.5">its own scheduler,</text>
<text x="665" y="118" fill="#6A6F8C" text-anchor="middle" font-size="8.5">its own tasks</text>
<path d="M665 166 V212" stroke="rgba(0,247,255,.5)" stroke-width="1.4" marker-end="url(#sc-ac)"/>
<rect x="20" y="214" width="860" height="130" rx="10" fill="rgba(255,255,255,.025)" stroke="rgba(255,255,255,.12)"/>
<text x="32" y="232" fill="#9A9DB0" font-size="9" letter-spacing="1.4">LEVEL 1 &#183; LINUX'S SCHEDULER &#183; CONTROL GROUPS SHARE THE PROCESSORS BY WEIGHT AND LIMIT</text>
<rect x="36" y="244" width="256" height="40" rx="6" fill="rgba(25,55,255,.22)" stroke="rgba(0,247,255,.5)"/>
<text x="164" y="268" fill="#00F7FF" text-anchor="middle">vCPU 0 carrier (a Linux task)</text>
<rect x="308" y="244" width="256" height="40" rx="6" fill="rgba(25,55,255,.22)" stroke="rgba(0,247,255,.5)"/>
<text x="436" y="268" fill="#00F7FF" text-anchor="middle">vCPU 1 carrier (a Linux task)</text>
<rect x="600" y="244" width="130" height="40" rx="6" fill="rgba(25,55,255,.16)" stroke="rgba(0,247,255,.35)"/>
<text x="665" y="268" fill="#5C93A8" text-anchor="middle">B's carriers</text>
<rect x="750" y="244" width="114" height="40" rx="6" fill="rgba(255,255,255,.06)" stroke="rgba(255,255,255,.16)"/>
<text x="807" y="268" fill="#9AA0BE" text-anchor="middle">host workloads</text>
<text x="300" y="306" fill="#C9CCE0" text-anchor="middle" font-size="9">sandbox A's control group: weight 100</text>
<text x="665" y="306" fill="#C9CCE0" text-anchor="middle" font-size="9">B: weight 100</text>
<text x="807" y="306" fill="#C9CCE0" text-anchor="middle" font-size="9">others</text>
<text x="450" y="332" fill="#6A6F8C" text-anchor="middle" font-size="9">A gets the same share whether it runs one task or five hundred, at whatever priorities</text>
</g>
</svg>
</figure>

## What the design has to achieve

Four things, and they pull against each other.

- **Exact.** Among a kernelet's own tasks, its scheduler's decisions hold exactly: which task runs on which virtual CPU, that a higher-priority wake-up preempts, that a time slice ends when the policy says. Linux never sees more runnable tasks of a kernelet than it has virtual CPUs.
- **Efficient.** Switching between two tasks of a sandbox should cost about what it costs Linux to switch between two threads of a control group, or less.
- **Fair.** Nothing a kernelet's scheduler does, by design, bug or malice, changes what another sandbox or the host receives.
- **Cooperative.** Linux must not take the processor from a virtual CPU at a moment that hurts the kernelet out of proportion, above all while the running task holds a spin lock. This is the classic disease of two-level scheduling, known from virtual machines as **lock-holder preemption**: the host deschedules the virtual CPU that holds a lock, and the guest's other virtual CPUs burn their time slices spinning on a lock whose holder is not running.

## The designs considered

Six families were explored; the losers are described, with their reasons, under [Alternatives considered](../alternatives.md#scheduling). In one table:

| design | exact | efficient | fair | cooperative | asks of Linux |
|---|---|---|---|---|---|
| translate the kernelet's decisions into Linux's `nice`, affinity and real-time parameters | no: only policies Linux can express, approximately | yes | real-time classes escape the group's share | no | nothing |
| keep a carrier per task, but let only the tasks the kernelet picked be runnable (the rest sleep) | yes | no: every switch is a Linux wake-up plus a Linux sleep, in both schedulers | yes | no | nothing |
| a BPF scheduler in Linux (`sched_ext`), fed the kernelet's choices through maps | yes | one Linux switch per switch | only if the BPF program reimplements group fairness | no | the machine's one BPF scheduler slot, for every tenant and the host |
| a hook in Linux's scheduler core that asks the kernelet which task to pick | yes | yes | yes | no | scheduler-core surgery; and it would run kernelet policy under Linux's run-queue lock |
| co-schedule all virtual CPUs of a sandbox at once (gang scheduling) | (not a policy mechanism) | wastes processors | yes | yes, by brute force | a scheduling class Linux does not have |
| **a carrier per virtual CPU; the kernelet multiplexes its own tasks on it** | **yes** | **a switch does not involve Linux at all** | **yes, by construction** | **yes, with the protocol below** | **one small helper and one export** |

The winner is the last. It is also the oldest idea on the list: it is what a virtual machine does, and what *scheduler activations* proposed for user-level threads in 1991, namely that the lower scheduler hands out processors and tells the upper one what happens to them. What is particular here is that the "virtual CPU" is an ordinary Linux task, that the upper scheduler is kernel code in the same address space, and that the two can therefore talk through a few words of shared memory at no cost.

## A carrier carries a virtual CPU {#vcpu}

Until now a [carrier](tasks.md#carriers) carried one kernelet task. From now on **a carrier carries one virtual CPU**, for the life of the sandbox. A sandbox configured with *N* virtual CPUs has *N* carriers, cloned from the root carrier when it starts, and never any more.

Kernelet tasks stop being Linux's business altogether. A task is OSTD's own object, with its own [kernelet stack](tasks.md#stacks), exactly as on a machine. OSTD's task layer, its context switch, its wait queues and its scheduler interface are the *same code* in vOSTD as on bare metal; what vOSTD virtualizes is one level lower, the CPU:

| what OSTD does on a machine | what vOSTD does on Linux |
|---|---|
| start the other processors at boot | the service `vcpu_boot(i)` lets carrier *i* enter the image |
| switch tasks: save and load callee-saved registers and the stack pointer | identical; Linux is not involved and does not notice |
| idle a processor with nothing to run (`hlt`) | the service `vcpu_idle(deadline)`: the carrier sleeps in Linux until something is pending |
| tell another processor to reschedule (an inter-processor interrupt) | the service `vcpu_kick(i)` |
| take a timer interrupt every tick | a [virtual interrupt](#upcall), from the endovisor |
| run with interrupts or preemption disabled | a counter in the virtual CPU's record, which [Linux honors](#cooperative) |

So when the kernel proper's scheduler decides that task B should replace task A on virtual CPU 0, vOSTD saves A's registers, loads B's, and B runs: on the same carrier, in the same Linux time slice, in a few dozen nanoseconds. If B is a tenant thread of a different process than the one last in user mode on this carrier, the carrier also [adopts that process's Linux address space](memory.md#cache) on its way to user mode, and the kernel proper saves and restores floating-point state as it does on a machine, through OSTD's `FpuContext`, which vOSTD backs with two services.

What Linux sees of a sandbox is *N* tasks in one control group. That is the whole interface between the two schedulers in the downward direction, and it is what makes fairness an argument and not a mechanism ([below](#fair)).

## Virtual interrupts {#upcall}

A scheduler needs to be *interrupted*: by the tick that ends a time slice, by the wake-up on another CPU that makes a higher-priority task runnable here. A kernelet has no interrupts. The endovisor gives it virtual ones, delivered into whatever the virtual CPU is doing.

Each virtual CPU has a small **record**, shared between the endovisor and vOSTD. The endovisor sets bits in its `pending` word: TICK, KICK, TIMER, and one per [virtual device line](interrupts-and-time.md). vOSTD keeps a `masked` depth there, raised by every preemption guard, every interrupts-off guard and every spin lock the kernel proper takes, which are the moments when a machine's interrupts would be off or preemption forbidden.

The source of ticks is the [watch timer](tasks.md#watch): one Linux timer per processor, which a carrier arms whenever it enters the kernelet, and which fires every millisecond, in hard-interrupt context, on the processor the carrier is running on. Each time it fires on a virtual CPU's carrier it sets TICK, and then delivers according to what it interrupted:

<figure class="fwd-fig">
<div class="head">
<div class="tag">The life of a scheduling decision</div>
<div class="title">A tick ends a time slice: the kernelet's scheduler runs, and Linux only watches</div>
</div>
<svg viewBox="0 0 900 300" role="img" aria-label="Task A is running on virtual CPU 0. One: the watch timer fires on that processor and sets the TICK bit in the virtual CPU's record. Two: if A was in user mode, the endovisor flags the carrier, which re-enters the kernelet through the gate; if A was in kernelet code with nothing masked, the endovisor points the interrupted frame at the image's upcall stub. Three: in the kernelet, the upcall saves A's registers on A's own kernelet stack and runs the tick handler, which calls the kernel proper's scheduler: update current, then pick next. Four: the scheduler picks task B; vOSTD switches stacks from A to B. Five: B runs on the same carrier; A waits in the kernelet's run queue with its interrupted state on its own stack, and will resume from there on whichever virtual CPU next picks it.">
<defs>
<linearGradient id="sd-cg" x1="0" y1="0" x2="1" y2="0">
<stop offset="0%" stop-color="#00F7FF" stop-opacity=".22"/>
<stop offset="100%" stop-color="#1937FF" stop-opacity=".22"/>
</linearGradient>
<marker id="sd-ac" viewBox="0 0 8 8" refX="7" refY="4" markerWidth="7" markerHeight="7" orient="auto-start-reverse">
<path d="M0 0 L8 4 L0 8 z" fill="#00F7FF"/>
</marker>
</defs>
<g font-family="ui-monospace,monospace" font-size="9.5">
<rect x="20" y="20" width="200" height="120" rx="8" fill="rgba(255,255,255,.06)" stroke="rgba(255,255,255,.16)"/>
<text x="32" y="40" fill="#9A9DB0" font-size="9" letter-spacing="1.2">1 LINUX &#183; WATCH TIMER</text>
<text x="32" y="64" fill="#C9CCE0">fires on this processor,</text>
<text x="32" y="80" fill="#C9CCE0">in hard-interrupt context;</text>
<text x="32" y="96" fill="#C9CCE0">interrupted: vCPU 0's carrier,</text>
<text x="32" y="112" fill="#C9CCE0">running task A</text>
<rect x="240" y="20" width="200" height="120" rx="8" fill="rgba(25,55,255,.22)" stroke="rgba(0,247,255,.5)"/>
<text x="252" y="40" fill="#00F7FF" font-size="9" letter-spacing="1.2">2 ENDOVISOR &#183; DELIVER</text>
<text x="252" y="64" fill="#C9CCE0">set TICK in the record</text>
<text x="252" y="84" fill="#8FF6FC">A in user mode: flag the</text>
<text x="252" y="98" fill="#8FF6FC">carrier; it returns by the gate</text>
<text x="252" y="116" fill="#8FF6FC">A in kernelet code, unmasked:</text>
<text x="252" y="130" fill="#8FF6FC">saved ip := the upcall stub</text>
<rect x="460" y="20" width="200" height="120" rx="8" fill="url(#sd-cg)" stroke="rgba(0,247,255,.55)"/>
<text x="472" y="40" fill="#8FF6FC" font-size="9" letter-spacing="1.2">3 vOSTD &#183; THE UPCALL</text>
<text x="472" y="64" fill="#C9CCE0">save A's registers on A's</text>
<text x="472" y="80" fill="#C9CCE0">own kernelet stack</text>
<text x="472" y="100" fill="#C9CCE0">run the tick handler:</text>
<text x="472" y="116" fill="#C9CCE0">scheduler.update_current(Tick)</text>
<rect x="680" y="20" width="200" height="120" rx="8" fill="url(#sd-cg)" stroke="rgba(0,247,255,.55)"/>
<text x="692" y="40" fill="#8FF6FC" font-size="9" letter-spacing="1.2">4 KERNEL PROPER'S SCHEDULER</text>
<text x="692" y="64" fill="#C9CCE0">A's slice is over</text>
<text x="692" y="84" fill="#C9CCE0">pick_next() = task B</text>
<text x="692" y="108" fill="#5C93A8" font-size="8.5">its policy, its run queues;</text>
<text x="692" y="122" fill="#5C93A8" font-size="8.5">Linux is not consulted</text>
<rect x="240" y="180" width="640" height="100" rx="8" fill="rgba(0,247,255,.04)" stroke="rgba(0,247,255,.42)"/>
<text x="252" y="200" fill="#00F7FF" font-size="9" letter-spacing="1.2">5 vOSTD &#183; SWITCH, AND CARRY ON</text>
<text x="252" y="224" fill="#C9CCE0">switch stacks from A to B: B runs now, on the same carrier, in the same Linux time slice</text>
<text x="252" y="244" fill="#C9CCE0">A waits in the kernelet's run queue; its interrupted registers and instruction pointer are on its</text>
<text x="252" y="260" fill="#C9CCE0">own stack, so whichever virtual CPU picks it next resumes it exactly where the tick found it</text>
<rect x="20" y="180" width="200" height="100" rx="8" fill="rgba(255,255,255,.025)" stroke="rgba(255,255,255,.12)"/>
<text x="32" y="200" fill="#9A9DB0" font-size="9" letter-spacing="1.2">IF MASKED</text>
<text x="32" y="222" fill="#C9CCE0" font-size="9">the bit stays pending;</text>
<text x="32" y="238" fill="#C9CCE0" font-size="9">vOSTD delivers it itself</text>
<text x="32" y="254" fill="#C9CCE0" font-size="9">when the last guard drops</text>
<g stroke="#00F7FF" stroke-width="1.4" fill="none">
<path d="M220 80 H238" marker-end="url(#sd-ac)"/><path d="M440 80 H458" marker-end="url(#sd-ac)"/><path d="M660 80 H678" marker-end="url(#sd-ac)"/><path d="M780 140 V178" marker-end="url(#sd-ac)"/>
</g>
</g>
</svg>
</figure>

- **In user mode.** The endovisor [flags the carrier](user-mode.md#gate); on its way back to user mode the gate's resume hook re-enters the kernelet, `user_run` returns *look for events*, and vOSTD's `execute` loop handles what is pending and then lets the scheduler preempt, which is what it does after a timer interrupt on a machine.
- **In kernelet code, with nothing masked.** The endovisor stores the interrupted instruction pointer in the record and points the interrupted frame at the image's **upcall stub**, by the same means as [eviction](../faults-and-reclamation.md#eviction). The stub, which is vOSTD's, pushes that instruction pointer, every register and the flags onto the *current task's* kernelet stack, runs the handlers for what is pending, and then does what a machine's interrupt return should do for a kernel that preempts: if the scheduler wants another task and nothing is masked, it switches. Because the interrupted state is on the task's own stack, the preempted task can resume later on any virtual CPU.
- **In kernelet code, masked.** Nothing is redirected. The bit stays pending, and vOSTD delivers it itself when the outermost guard drops, which costs one load and a branch on that path.
- **Anywhere else** (inside a service call, in Linux's code): pending until the carrier is back in the kernelet.

A virtual CPU that Linux has descheduled receives no ticks while it is off the processor. vOSTD's tick handler therefore reads the clock and accounts for the time that actually passed; it does not count ticks. This is the same adjustment a guest kernel makes for *steal time* under a hypervisor.

`vcpu_kick(i)` is the inter-processor interrupt. OSTD calls it where a machine would send a reschedule interrupt, typically when `enqueue` places a newly runnable task on another CPU's queue. The endovisor sets KICK and then does the least that will get it seen: wakes carrier *i* if it is asleep in `vcpu_idle`, flags it if it is in user mode (which interrupts its processor), and otherwise leaves the bit for the next guard drop or watch tick.

**What OSTD must gain.** One thing, and it is worth having on a machine too: **preemption of kernel-mode code on return from an interrupt**. Today OSTD lets the scheduler preempt a task when it returns from user mode, when it drops its last preemption guard, and when it yields; a kernel task that computes without taking a guard is never preempted. The upcall's last step is that missing preemption point. Everything else above is a new body for something OSTD already has.

## Sharing the processor with Linux, at convenient moments {#cooperative}

Linux will preempt a carrier whenever its own policy says so: the sandbox's time slice in its control group is over, a host task with a better claim woke up. If that happens while the kernelet task on that carrier holds a kernelet spin lock, every other virtual CPU that wants the lock spins until Linux runs the first one again. That is lock-holder preemption, and hypervisors have fought it for twenty years with two families of remedy: *tell the host when not to preempt*, and *make waiting cheap when it preempted anyway*. The design uses both, the first as the rule and the second as the backstop.

<figure class="fwd-fig">
<div class="head">
<div class="tag">Cooperating</div>
<div class="title">Linux's preemption waits for the kernelet's critical section, for a bounded time</div>
</div>
<svg viewBox="0 0 900 250" role="img" aria-label="A timeline of one virtual CPU. The kernelet task takes a spin lock: vOSTD raises the masked depth and, with the same instruction Linux uses, Linux's own preemption count. While the lock is held, Linux decides the carrier should be preempted and marks it; because the count is raised, Linux does not preempt. The task releases the lock: the count drops to zero, vOSTD sees that Linux is waiting and calls the vcpu_yield service at once, and Linux switches to another task. A second, lower timeline shows a task that overstays: the watch timer finds it still masked, with Linux waiting, on two consecutive ticks, and forces the yield.">
<defs>
<marker id="co-ac" viewBox="0 0 8 8" refX="7" refY="4" markerWidth="7" markerHeight="7" orient="auto-start-reverse">
<path d="M0 0 L8 4 L0 8 z" fill="#00F7FF"/>
</marker>
</defs>
<g font-family="ui-monospace,monospace" font-size="9.5">
<text x="20" y="24" fill="#00F7FF" font-size="9" letter-spacing="1.4">THE RULE</text>
<path d="M20 70 H880" stroke="rgba(255,255,255,.28)" stroke-width="1"/>
<rect x="60" y="52" width="120" height="36" rx="4" fill="rgba(255,255,255,.06)" stroke="rgba(255,255,255,.16)"/>
<text x="120" y="74" fill="#9AA0BE" text-anchor="middle">kernelet code</text>
<rect x="180" y="52" width="300" height="36" rx="4" fill="rgba(25,55,255,.30)" stroke="rgba(0,247,255,.55)"/>
<text x="330" y="68" fill="#8FF6FC" text-anchor="middle">holding a spin lock</text>
<text x="330" y="82" fill="#5C93A8" text-anchor="middle" font-size="8.5">masked &gt; 0, and Linux's preemption count raised</text>
<rect x="480" y="52" width="70" height="36" rx="4" fill="rgba(0,247,255,.16)" stroke="rgba(0,247,255,.55)"/>
<text x="515" y="74" fill="#00F7FF" text-anchor="middle">yield</text>
<rect x="550" y="52" width="200" height="36" rx="4" fill="rgba(255,255,255,.03)" stroke="rgba(255,255,255,.12)" stroke-dasharray="4 3"/>
<text x="650" y="74" fill="#6A6F8C" text-anchor="middle">Linux runs someone else</text>
<path d="M330 30 V50" stroke="#9AA0BE" stroke-width="1.2" marker-end="url(#co-ac)"/>
<text x="338" y="40" fill="#9AA0BE" font-size="8.5">Linux wants the processor: it marks the carrier, and waits</text>
<text x="480" y="106" fill="#00F7FF" font-size="8.5" text-anchor="middle">lock released: count reaches zero with Linux waiting</text>
<text x="480" y="119" fill="#00F7FF" font-size="8.5" text-anchor="middle">vOSTD calls vcpu_yield() at once</text>
<text x="20" y="156" fill="#00F7FF" font-size="9" letter-spacing="1.4">THE BOUND</text>
<path d="M20 200 H880" stroke="rgba(255,255,255,.28)" stroke-width="1"/>
<rect x="60" y="182" width="560" height="36" rx="4" fill="rgba(25,55,255,.30)" stroke="rgba(0,247,255,.55)"/>
<text x="340" y="204" fill="#8FF6FC" text-anchor="middle">a task that holds its guard for too long</text>
<rect x="620" y="182" width="90" height="36" rx="4" fill="rgba(0,247,255,.16)" stroke="rgba(0,247,255,.55)"/>
<text x="665" y="204" fill="#00F7FF" text-anchor="middle">forced yield</text>
<g stroke="#9AA0BE" stroke-width="1.2">
<path d="M260 170 V182"/><path d="M440 170 V182"/><path d="M620 170 V182"/>
</g>
<g fill="#9AA0BE" font-size="8.5" text-anchor="middle">
<text x="260" y="166">tick: Linux starts waiting</text><text x="440" y="166">tick: strike one</text><text x="620" y="166">tick: strike two</text>
</g>
<text x="450" y="238" fill="#6A6F8C" text-anchor="middle" font-size="9">at most two ticks of grace; the extra time is charged to the sandbox like any other</text>
</g>
</svg>
</figure>

**The rule: the kernelet's guards are Linux's guards.** Linux keeps, per processor, a *preemption count*; while it is non-zero Linux does not preempt the running task, and Linux's own `preempt_disable()` is nothing but an increment of it ([`asm/preempt.h`](https://elixir.bootlin.com/linux/v6.12/source/arch/x86/include/asm/preempt.h#L92)). When the kernel proper takes a preemption guard, an interrupts-off guard or a spin lock, vOSTD raises its own `masked` depth *and executes that same increment*, on Linux's counter, whose per-processor location the endovisor publishes in the boot arguments ([`pcpu_hot`](https://elixir.bootlin.com/linux/v6.12/source/arch/x86/include/asm/current.h#L15) is exported). Dropping the guard executes the matching decrement. On x86 Linux folds "a reschedule is wanted" into that same word, inverted, so the decrement's zero flag says *the count is zero and Linux is waiting for this processor*; when it does, vOSTD calls the service `vcpu_yield()`, which reschedules in Linux. This is, instruction for instruction, what Linux's own `preempt_enable()` does.

The effect is that Linux defers an involuntary preemption of a virtual CPU until the kernelet's critical section ends, by Linux's own mechanism, and that the kernelet gives the processor up the moment it can. On a Linux that does not preempt kernel code at all, the [watch timer](tasks.md#watch) plays Linux's part: it sends the carrier through the yield stub only when `masked` is zero, and otherwise waits for the guard to drop.

**The mirror exists only while kernelet code runs.** A service may sleep, and Linux forbids sleeping with the count raised. OSTD does call one service under a guard (its TLB flusher holds a preemption guard across the flush). So every [service stub](../kernelet-api-service.md#depth), on its way to the Linux stack, takes out of Linux's count what the kernelet's guards added, and puts it back on return. It does not ask the kernelet how much that is: the endovisor recorded Linux's count when the carrier entered kernelet code, and the excess over that value is the kernelet's. The same subtraction is made by every other path that takes a carrier out of kernelet code, the yield stubs and the [exit stub](../faults-and-reclamation.md#leaving), so that a kernelet which miscounts, or is evicted with a lock held, leaves Linux's count exactly as Linux expects it. The kernelet's own meaning of the guard is unaffected: nobody else can touch this virtual CPU's data, because nobody else *is* this virtual CPU.

**The bound: two strikes.** A guard that is held is a processor that Linux cannot take, so it must not be held for long, and "must not" has to be enforced against a kernel proper whose logic the tenant may control. The watch timer fires in hard-interrupt context whatever the count. When it finds a carrier in kernelet code, masked, with Linux waiting, it notes it. If it finds the same at the next tick, it **forces the yield**: it sends the carrier through a stub that saves every register, switches to the Linux stack, takes the kernelet's excess out of Linux's count as a service stub does, calls `schedule()`, and puts everything back. The grace is therefore at most two ticks, 2 ms, which is within what Linux tolerates from its own non-preemptible sections. It is also *borrowed, not stolen*: Linux accounts the extra run time to the sandbox's control group like any other, so the sandbox's long-run share does not grow by a microsecond. What a neighbor can lose is latency, at most the grace, per preemption. Forced yields are counted per sandbox, and a sandbox that collects them is misbehaving in a way the operator can see.

**The backstop: do not spin on a lock whose holder is not running.** After a forced yield, or when Linux preempts a virtual CPU in user mode while another spins, a waiter can still meet a lock whose holder is off the processor. vOSTD's spin-lock slow path, after about a thousand failed spins, calls the service `vcpu_on_spin()`, and the endovisor hands the waiter's time to a sibling carrier that is runnable but not running, with Linux's exported [`yield_to()`](https://elixir.bootlin.com/linux/v6.12/source/kernel/sched/syscalls.c#L1468). This is what KVM does for its guests ([`kvm_vcpu_on_spin()`](https://elixir.bootlin.com/linux/v6.12/source/virt/kvm/kvm_main.c#L4020)), without the hardware that tells KVM a guest is spinning, which vOSTD does not need because it *is* the spin lock.

## Why a kernelet's scheduling cannot hurt its neighbors {#fair}

The argument has three steps, and none of them trusts the kernel proper's scheduler.

1. **Linux sees *N* tasks, whatever happens inside.** Task creation, priorities, policies, run queues, a scheduler that starves its own tasks or loops: all of it is state inside the kernelet. The carriers are created once, by the endovisor, with one `nice` value, in the sandbox's control group. The kernelet has no service that changes a carrier's Linux priority, class or affinity.
2. **The control group bounds the *N* tasks.** Linux's group scheduling gives the group its weight's share however many of its tasks are runnable, and its bandwidth limit if it has one ([background](../background.md#scheduler)). One busy kernelet task or five hundred is the same *N* busy carriers.
3. **The three ways a virtual CPU can resist Linux are each bounded.** A guard delays preemption by at most two ticks, charged. Kernelet code that never yields on a non-preemptible Linux is [made to](tasks.md#watch). A kernelet that will not stop at all is [evicted](../faults-and-reclamation.md#eviction).

What remains is the interrupt-time residue the chapter already lists: the watch timer's interrupts, one per millisecond per processor that is running kernelet code, are charged to whatever they interrupt, which is the sandbox's own carrier.

## What this asks for

**Of OSTD**, one enhancement and one convention. The enhancement is kernel-mode preemption on interrupt return, above. The convention is that the preemption-guard depth and the spin-lock slow path go through two small architecture hooks (raise/drop, and "I am spinning"), which on a machine do what they do today. The `Scheduler` and `LocalRunQueue` traits are unchanged: a scheduler written for bare-metal OSTD runs in a kernelet as it is.

**Of Linux**, beyond the chapter's [ledger](../endovisor.md#patch): one helper and one export. A carrier that runs tenant threads of several processes must be able to change which Linux address space it runs on ([Memory](memory.md#cache)). Linux has the operation for kernel threads ([`kthread_use_mm()`](https://elixir.bootlin.com/linux/v6.12/source/kernel/kthread.c#L1439)) and for `exec` ([`exec_mmap()`](https://elixir.bootlin.com/linux/v6.12/source/fs/exec.c#L958)), but not for a user task that wants to swap between address spaces it holds references to. The patch adds `kernelet_switch_mm()`, a few dozen lines modelled on those two, and exports [`mm_alloc()`](https://elixir.bootlin.com/linux/v6.12/source/kernel/fork.c#L1327) so that the endovisor can create an address space per tenant process.

Nothing is asked of Linux's scheduler itself: no class, no hook, no BPF program, no new flag. The sandbox's share is set with the files every container runtime already writes (`cpu.weight`, `cpu.max`, `cpuset.cpus`), which need a Linux built with group scheduling, as distribution kernels are.

## Costs

- **Per switch between kernelet tasks**: OSTD's own context switch, a save and a load of callee-saved registers, and no crossing at all between two kernel threads. Between two tenant threads add two service calls for the [floating-point state](user-mode.md#fpu), and between tenant threads of different processes one [address-space switch](user-mode.md#adopt) at the next `user_run`.
- **Per preemption guard or spin lock**: one extra increment and one extra decrement of a per-processor word that is already in the first-level cache (*estimated* at under a nanosecond each).
- **Per tick on a running virtual CPU**: one hard-interrupt timer callback, and one upcall or one flagged return from user mode, about a microsecond (*estimated*).
- **Per wake-up of a task on another virtual CPU**: one `vcpu_kick`, which is a Linux wake-up if that virtual CPU is idle, a flag if it is in user mode, and a bit otherwise.
- **Per Linux preemption that finds a guard held**: at most two ticks of delay for whoever Linux wanted to run, charged to the sandbox.

**[unverified]**: the prototype's fourth phase, which measures these against native Linux threads in a control group, is being built; [the prototype page](../prototype.md) will carry the numbers.

## What a tenant sees

Its kernel's scheduler, working. `nice`, real-time priorities, affinity to virtual CPUs and time slices mean what the kernel proper says they mean, among the sandbox's own tasks. What a tenant can also see is what a guest of any hypervisor sees: its virtual CPUs are not always running, so a task can lose the processor for a stretch that its own scheduler did not decide, and wall-clock time can pass without ticks. A tenant that configures more virtual CPUs than its control group's limit can pay for will see more of that, not less.

## What this page decides

- **A carrier carries a virtual CPU, and the kernelet multiplexes its own tasks on it with OSTD's own task layer** (register D116). It revises D93 (a carrier per task) and retires the seat of D88, which a virtual CPU now is, permanently. For the Linux host it revises D15, "the kernel proper's scheduler is inert". The alternatives are in the table above.
- **The kernelet is interrupted by upcalls: the endovisor redirects an unmasked virtual CPU to the image's upcall stub, and leaves a bit pending for a masked one** (register D117). It replaces the worker tasks and jobs of the earlier design, and the user-mode tick.
- **OSTD gains kernel-mode preemption on interrupt return** (register D118), a prerequisite, useful on a machine too.
- **The kernelet's guard depth is mirrored into Linux's preemption count while kernelet code runs, with a grace of at most two ticks enforced by the watch timer, and `yield_to()` as the backstop for spinning** (register D119). The alternatives were to let Linux preempt anywhere and only treat the symptom, which is what the backstop alone would be, or to require a Linux that never preempts kernel code.
- **The patch gains `kernelet_switch_mm()` and the export of `mm_alloc()`** (register D120), because a virtual CPU runs threads of many address spaces. The alternative, re-pointing one address space at a different model on every switch, would empty its page table each time.
