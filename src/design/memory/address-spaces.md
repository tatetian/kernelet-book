# Address spaces

A kernelet drives its tenants' address spaces through OSTD's `VmSpace` and cursor exactly as today; that is the one library item whose internals hold a host-side resource on the kernelet's stack (per-node lock bits under a preemption guard), and Alternative A's treatment is kept: the cursor bumps the host lock depth on creation and drop; its escapes (node allocation, a service call while held, remote flush posting, deferred frees, the flush handler) are enumerated and tested; long `vmar` operations are chunked one 2 MiB leaf table per cursor operation with a preemption point between; kernelet-owned deferred frame drops are parked on a per-owner list instead of running on whoever switches next.

Two things change:

- A `VmSpace` is created through the host (`new_address_space`), which draws the root node reservation-first, copies the top-level kernel entries **from the kernelet's kernel page table** (so [entry 500](../process/two-windows.md) is the kernelet's window; that table outlives every space created from it, which is what OSTD's unrefcounted sharing of kernel nodes requires), and records a strong reference in a per-kernelet table until `release_address_space` or destroy, so that no space is ever held only by an idle CPU's active-space pointer.
- `bind_address_space(thread, &space)` validates that the root's frames are owner-tagged to the calling kernelet before the host will ever load it into CR3; it is the one authority check outside the resolver.
