# Layer 4: threads and scheduling

Tasks are host-owned and named by the kernelet; there are two lock guardians and a quiescence predicate; one preemptive hierarchical scheduler, with Alternative B's task groups as the kernelet's CPU budget and its interrupt-handler task as the kernelet's worker; and a stack check at every crossing.

This layer guarantees that a kernelet lock never delays killing its kernelet, and that a kernelet cannot pin a CPU or exhaust a host stack. It is enforced by the two guardian types, the tick, and the facade's refusal of interrupt control.

In this chapter:

- [Tasks are host-owned; the kernelet names them](tasks.md)
- [Blocking stays synchronous](blocking.md)
- [One scheduler, hierarchical, preemptive](scheduler.md)
- [Two guardians, and a kernelet's "interrupts"](guardians.md)
- [The stack check at the boundary](stack-check.md)
- [The worker: deferred work by name, in thread context](worker.md)
