# C06: Idle and wake CPU cost

**Status:** adopted, minor. **Depends on kernelets:** yes. **Acts on:** CPU, not memory: the cores that idle and waking sandboxes consume.

## The problem, measured

An idle restored Firecracker VM (Linux 6.1 guest, tickless idle) consumed **2 ticks in 60 s**, 0.03 % of one core, from its vCPU thread's timer wakeups and the VMM's own polling (`../../benchmark/results/firecracker-raw.md`). Small per VM, but at 10,000 idle VMs it is **3 cores**, and it is the floor: a guest with a less careful kernel configuration, a `systemd` inside, or an agent that polls, costs more. A wake costs a VMM restore (18–36 ms of host CPU measured, mostly VMM and KVM state) when the VM was paused to disk, plus the page faults of the working set through the EPT.

## The mechanism

A kernelet has no vCPU thread and no timer of its own: its threads are host threads, parked when idle; its ticks are counted by the host tick into a shared record and consumed only when a task runs (Blueprint, Interrupts and time, register D66); an idle kernelet gets a `JOB_TICK` at `idle_tick_hz`, which the policy sets to **0** for agent sandboxes, with `timer_arm` for the kernel's real timers. An idle kernelet then costs exactly the host tick's charge check, one compare per tick on the CPU that happens to run it, which is zero while nothing runs. A wake is one `task_unpark`, no VMM, no vCPU creation, no EPT; the working set faults in through the host's own page fault path (C03) without a VM exit per page.

## Gain

Idle: from 0.03 % of a core per sandbox to ~0, **3 cores per 10,000** on the model server. Wake: from ~30 ms of host CPU per VM restore to microseconds, which at 17 wakes/s is half a core saved. Active work: the Paper's measurement of a page fault at 10,345 cycles in the prototype against 9,791 native says a kernelet's system calls and faults are within 6 % of native, where a VM pays an exit per I/O completion and per timer; that is a throughput gain for `c_active`, not a density gain, and it is not counted here.

## Evidence

- Measured: 0.03 % of a core per idle VM; 18–36 ms per restore.
- Analytic: the kernelet's idle cost is zero by construction of D66 and `idle_tick_hz = 0`.

## Isolation

None.

## Cost

None beyond the Blueprint's design; `idle_tick_hz = 0` makes an idle sandbox's kernel timers depend on `timer_arm`, which the Blueprint lists as the tickless extension (Interrupts and time); without it an idle kernelet's sleeping processes wake only on external events, which for an agent that waits on messages is the intended behavior.

## Changes to the Blueprint

Recorded here, not applied: `timer_arm` promoted from extension to required, with the `cfg` line in the kernel proper's real-time timer manager that reports its earliest deadline.
