# C06: Idle CPU cost

**Status:** adopted as a Blueprint correction; density effect below the model's resolution, revised after review. **Depends on kernelets:** yes. **Acts on:** CPU.

## Measured

An idle restored Firecracker VM with `sleep` as init used 2 scheduler ticks in 60 s (≤ 0.03 % of a core, at the resolution of tick-sampled accounting). Measured more precisely with per-thread `schedstat` over 120 s, a resident Node.js 22 process with a live timer inside a 256 MiB guest cost **39 ms of CPU, 0.033 % of one core**, nearly all of it on the vCPU thread, on a host with KVM's default `halt_poll_ns` of 200 µs (`../../benchmark/results/firecracker-raw.md`, `node256b`). That is the VM's idle cost for a non-polling agent: about **3 cores per 10,000 idle sandboxes**. A polling agent, or a `systemd` guest, costs more, but the same polling costs a kernelet in proportion: per timer expiry the two paths (host timer, thread wake, guest or kernelet delivery, park) are the same class, a few microseconds each.

## The kernelet side

An idle kernelet costs the host tick's per-CPU charge check, which is zero while nothing of the kernelet runs, *if* the Blueprint's default `idle_tick_hz = 100` is changed to 0 for agent sandboxes and the kernel's own timers go through `timer_arm`. Two things the Blueprint has not designed follow: the host needs a deadline-ordered structure (a per-CPU timer heap or wheel) rather than a scan of 10,000 kernelets' deadlines per tick, which would itself cost a core; and the kernel proper's `cfg` line must report the minimum deadline over all four of its jiffies-driven timer managers (the realtime, monotonic and boottime clocks and the jiffies manager, `kernel/core/src/time/clocks/system_wide.rs`), not the one manager the Interrupts page names. With the Blueprint's default 100 Hz idle tick, an idle kernelet's worker wakes 100 times a second, about 0.03 % of a core, the same as the VM.

## Gain

At most 3 cores per 10,000 idle sandboxes, 2.7 % of the 128-core CPU bound, below the resolution of the model's parameters; the composition uses the same CPU bound for both systems. The first draft's "half a core saved on wakes" rested on Firecracker's 11–36 ms restore, which is wall time of unknown composition and applies only to hibernated VMs at the 5 s tier, where both systems are CPU-bound; it is withdrawn. The Paper's page-fault figure is not a system-call figure and is not cited here; per-operation CPU is C14's subject.

## Changes to the Blueprint

Recorded here, not applied: `idle_tick_hz = 0` as the agent-sandbox default; `timer_arm` required, with a host-side deadline heap and the four-manager `cfg` line.
