# Interrupts and time

*How a kernel that owns no interrupt controller receives interrupts, and how it tells the time. It discharges the rule that no kernelet code ever runs in Linux's interrupt context, which is what lets a carrier be stopped wherever it stands.*

## A kernelet has no interrupts, only virtual ones

Linux owns the interrupt controller, the vector table and every physical line. Nothing in vOSTD can register a hardware handler, mask a hardware interrupt or send one to another processor; OSTD's interfaces for those are absent from the kernelet build, so a use of one does not compile.

What a kernelet has instead are **virtual interrupts**. Each [virtual CPU](tasks.md#vcpus) has a record shared with the endovisor, and in it a `pending` word. The endovisor sets a bit; the kernelet's handler for that bit runs on that virtual CPU soon after, in *task context* on the virtual CPU's carrier, never in Linux's interrupt context. How "soon after" is arranged, including the case where the virtual CPU is in the middle of kernel code, is the **upcall**, specified on the [Scheduling](scheduling.md#upcall) page because the scheduler is its most demanding user. This page says what the bits are and what stands behind them.

| bit | meaning | set by |
|---|---|---|
| TICK | a millisecond of execution has passed on this virtual CPU | the [watch timer](tasks.md#watch), while the carrier is on a processor |
| TIMER | the deadline this virtual CPU asked for has passed | a Linux timer the endovisor armed for it |
| KICK | another virtual CPU wants this one to look at its run queue | the service `vcpu_kick` |
| lines 32 to 255 | a virtual device has something to say | a device model, through `raise_irq` |

The kernel proper's interrupt handlers, bottom halves and timer callbacks keep their code. `IrqLine` is OSTD's type with its callback lists; what is gone is everything beneath it: the mapping to a hardware vector and the acknowledgment. A handler runs inside the upcall with the virtual CPU's `masked` depth raised, so it is not interrupted by another on the same virtual CPU, which is the assumption such handlers make on a machine. Work that a machine would defer to a bottom half is deferred the same way, to OSTD's own mechanism, which runs when the handler returns.

**Raising a line.** A device model in the endovisor calls `raise_irq(line)`. Each device line is bound for the kernelet's life to one virtual CPU. Raising it is an atomic bit-set in that virtual CPU's `pending` word and a kick, both legal from any Linux context, including a hardware interrupt handler. Delivery is edge-triggered: a line raised twice before its handler runs is handled once, as with a real interrupt line.

**An idle virtual CPU.** When the kernelet's scheduler has nothing else to run on a virtual CPU, it runs the kernel proper's idle task, which calls OSTD's `halt_cpu()`, the function that on a machine halts the processor until the next interrupt. In vOSTD that is the service `vcpu_idle(deadline)`: the carrier sleeps in Linux, killably, until a bit is pending or the deadline passes. A kick or a raised line wakes it with [`wake_up_process()`](https://elixir.bootlin.com/linux/v6.12/source/kernel/sched/core.c#L4412).

## Time

**Reading the clock** needs no crossing. The endovisor publishes the processor's timestamp-counter frequency in the kernelet's boot arguments, and keeps one **clock page**, shared read-only by every kernelet on the machine, holding a coarse tick count and the monotonic time in nanoseconds. One Linux high-resolution timer updates it at the kernel proper's tick rate, machine-wide, not per kernelet. vOSTD's `Jiffies` and its clock sources read the page and the counter.

**The tick.** While a virtual CPU is running, in kernel or user mode, the [watch timer](tasks.md#watch) of the processor it is on sets TICK every millisecond. The tick handler runs the kernel proper's periodic work and tells its scheduler that time has passed. A virtual CPU that Linux has taken off the processor gets no ticks until it is back, so the handler measures elapsed time from the clock and does not count ticks; a virtual CPU that is idle gets none either, and needs none.

**Deadlines.** The kernel proper's timers live in its own timer wheel. vOSTD tells the endovisor only the earliest deadline of each virtual CPU: as the argument of `vcpu_idle` when the virtual CPU idles, and with `timer_arm(vcpu, deadline_ns)` when it is running and needs better than the tick's resolution. The endovisor keeps one Linux [`hrtimer`](https://elixir.bootlin.com/linux/v6.12/source/kernel/time/hrtimer.c#L1282) per virtual CPU for the purpose. Its callback runs in Linux's interrupt context and therefore does no kernelet work: it sets TIMER, kicks, and returns.

Time spent in a timer interrupt is charged to whatever it interrupts, not to the sandbox, so a kernelet must not be able to turn its charged processor time into a storm of uncharged interrupts by arming deadlines a nanosecond away. The endovisor rounds every deadline up to at least 50 µs from now, which is the slack Linux applies to an ordinary process's timers by default. A kernelet can then cause no more timer interrupts per virtual CPU than a Linux thread could with `nanosleep`.

An idle kernelet with no deadline armed costs Linux no timer interrupts at all, which matters when a machine holds thousands of them.

## What a tenant sees

Timers and sleeps behave as on the other host, at the resolution of Linux's high-resolution timers. Interrupt latency for a virtual device is the latency of waking or flagging a Linux task, a few microseconds (*estimated*), plus, when the virtual CPU is in kernel code with a guard held, the length of that critical section. `/proc/interrupts` inside the sandbox shows only virtual lines.

## Costs

- **Per virtual interrupt**: one atomic operation, and a wakeup or a flag if the virtual CPU is idle or in user mode.
- **Per deadline change**: one service call and one `hrtimer` re-arm.
- **Per millisecond that a virtual CPU runs**: one watch-timer interrupt.
- **Per machine**: one timer updating the clock page.

## What this page decides

- **No kernelet code runs in Linux's interrupt context; interrupts are bits in a virtual CPU's record, handled by an upcall on that virtual CPU's carrier** (register D117, which replaces the per-virtual-CPU worker tasks and job queue of D11 on this host). The alternative, calling a kernelet's handler from Linux's timer or device interrupt, would run tenant-driven code where it cannot be stopped, cannot sleep and cannot be charged.
- **An idle kernelet arms no timer** (register D101, kept). The alternative, a fixed tick per kernelet, makes the idle cost of a machine proportional to its sandbox count.
