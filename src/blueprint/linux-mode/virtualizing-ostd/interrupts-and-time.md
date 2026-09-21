# Interrupts and time

*How a kernel that owns no interrupt controller receives interrupts, and how it tells the time. It discharges the rule that no kernelet code ever runs in interrupt context, which is what lets a carrier be stopped wherever it stands.*

## A kernelet has no interrupts

Linux owns the interrupt controller, the vector table and every physical line. Nothing in vOSTD can register a hardware handler, mask an interrupt or send one to another processor; OSTD's interfaces for those are absent from the kernelet build, so a use of one does not compile.

What a kernelet has instead is three things, all delivered in *task context*:

- **virtual interrupt lines**, raised by the endovisor when a virtual device has something to say;
- **jobs**, units of deferred work that a per-virtual-CPU **worker** task fetches and runs;
- **deadlines**, which the kernelet asks the endovisor to turn into a job at a given time.

The kernel proper's drivers, bottom halves and timer callbacks keep their code. They run on the worker, which is an ordinary kernelet task on an ordinary [carrier](tasks.md#carriers).

## Workers and jobs

Each virtual CPU of a kernelet has one worker. The endovisor asks for them when it creates the kernelet, and gives their carriers a higher Linux priority than the kernelet's other carriers, so that Linux serves an interrupt before it serves ordinary work, which is what interrupt priority does for a real kernel.

A worker's body is a loop in vOSTD around one service call:

```rust
loop {
    let job = services().job_wait();      // sleeps in Linux until a job is posted for this virtual CPU
    match job.kind() {
        JOB_VIRQ  => deliver_virq(job.line()),   // run the line's handlers, then its bottom halves
        JOB_TICK  => tick::run(seat_record().take_ticks()),  // expire timers, run the kernel proper's tick callbacks
        JOB_GRANT => grant::add_new_runs(),      // new memory appeared in the grant table
    }
}
```

`job_wait` is a killable sleep on a Linux wait queue in the endovisor. Posting a job is an atomic bit-set on the kernelet's pending word and a [`wake_up_process()`](https://elixir.bootlin.com/linux/v6.12/source/kernel/sched/core.c#L4412) of the worker's carrier, and both are legal from any Linux context, including a hardware interrupt handler. Delivery is edge-triggered: a line raised twice before the worker runs is one job, as with a real interrupt line.

**Raising a line.** A device model in the endovisor calls `raise_irq(line)`. Lines are numbered 0 to 255: 0 to 31 are reserved (the tick, which would be line 0 on a machine, arrives as a job of its own kind), 32 and above are device lines, each bound for the kernelet's life to one virtual CPU. The kernel proper sees `IrqLine` exactly as OSTD defines it, with its callback lists; what is gone is everything beneath: the mapping to a hardware vector and the acknowledgment.

**The handlers' assumptions still hold.** An interrupt handler in the kernel proper assumes it is not interrupted by another on the same CPU. The worker holds its [seat](tasks.md#seats) and raises the no-preemption counter for the handler's duration, and no other worker exists for that virtual CPU, so the assumption holds by construction.

## Time

**Reading the clock** needs no crossing. The endovisor publishes the processor's timestamp-counter frequency in the kernelet's boot arguments, and keeps one **clock page**, shared read-only by every kernelet on the machine, holding a coarse tick count and the monotonic time in nanoseconds. One Linux high-resolution timer updates it at the kernel proper's tick rate, machine-wide, not per kernelet. vOSTD's `Jiffies` and its clock sources read the page and the counter.

**Deadlines.** The kernel proper's timers live in its own timer wheel. vOSTD tells the endovisor only the earliest deadline per virtual CPU, with `timer_arm(seat, deadline_ns)` (a seat *is* a virtual CPU; the two words name the same number). The endovisor keeps one Linux [`hrtimer`](https://elixir.bootlin.com/linux/v6.12/source/kernel/time/hrtimer.c#L1282) per virtual CPU. Its callback runs in Linux's interrupt context and therefore does no kernelet work: it posts a `JOB_TICK` and returns.

Time spent in a timer interrupt is charged to whatever it interrupts, not to the sandbox, so a kernelet must not be able to turn its charged processor time into a storm of uncharged interrupts by arming deadlines a nanosecond away. The endovisor rounds every deadline up to at least 50 µs from now, which is the slack Linux applies to an ordinary process's timers by default. A kernelet can then cause no more timer interrupts than a Linux process could with `nanosleep`.

**The periodic tick.** The kernel proper also expects a regular tick, to account time and to run its periodic callbacks. While a carrier holds a seat, that seat's timer fires at the kernel proper's tick rate. Its callback adds one to a count in the seat's shared record and posts a `JOB_TICK` to the seat's worker, once, however many ticks accumulate. The worker runs when the seat is next free, reads and clears the count, and runs the kernel proper's tick work for that many ticks. A tick is thus handled *between* stretches of other kernelet code on that virtual CPU, never in the middle of one, which the kernel proper's tick code tolerates because ticks already arrive late and in batches on a busy machine. When no carrier holds the seat and no deadline is armed, the timer is not armed at all. A seat is held only by a carrier that is inside kernelet code at that moment, so a kernelet never has more tick timers running than it has carriers inside its code, however many seats it was configured with. An idle kernelet costs Linux no timer interrupts, which matters when a machine holds thousands of them.

## What a tenant sees

Timers and sleeps behave as on the other host, at the resolution of Linux's high-resolution timers rather than of a fixed tick. Interrupt latency for a virtual device is the latency of waking a Linux task, a few microseconds (*estimated*), plus any wait for the virtual CPU's seat. `/proc/interrupts` inside the sandbox shows only virtual lines.

## Costs

- **Per virtual interrupt**: one atomic operation and one Linux task wakeup.
- **Per deadline change**: one service call and one `hrtimer` re-arm.
- **Per busy tick**: one Linux timer interrupt and one atomic increment, only while the kernelet is running.
- **Per machine**: one timer updating the clock page.

## What this page decides

- **No kernelet code runs in Linux's interrupt context; interrupts are jobs on a worker** (register D11, kept). The alternative, calling a kernelet's handler from the timer or device interrupt, would run tenant-driven code where it cannot be stopped, cannot sleep and cannot be charged.
- **An idle kernelet arms no timer** (register D101). The alternative, a fixed tick per kernelet, makes the idle cost of a machine proportional to its sandbox count.
