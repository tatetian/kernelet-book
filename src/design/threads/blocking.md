# Blocking stays synchronous

A kernelet thread that blocks in `read()` sleeps inside the kernelet holding its kernel stack, as today. The alternative, making every block a return value and restarting the syscall, was worked out in full for Alternative A and rejected: it touches about fifty blocking sites and every fallible user copy, creates a TOCTOU surface the tree does not have, deviates observably from Linux, and nothing in H1–H9 needs it. What keeping the stack costs is that destroy must *abandon* parked stacks, and [§4.7.1](../faults/tiers.md) shows that is sound.
