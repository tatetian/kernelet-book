# C14: CPU per operation

**Status:** adopted as a sensitivity on the CPU bound, revised after review; the workload fraction it applies to is unverified, and the upper end holds only against VMs whose guest memory is not hugepage-backed. **Depends on kernelets:** yes. **Acts on:** `c_active`, the CPU an active sandbox consumes, which is the binding resource once idle sandboxes leave DRAM on both sides.

## Why it matters

Once idle sandboxes are paged out on both sides (C03 and its VM equivalents), memory no longer binds and the density of both systems is `cores / (a · c_active)`. The only way one system holds more sandboxes than the other is then to spend less CPU per unit of tenant work.

## Measured

Inside a 1-vCPU Firecracker guest and on the host, the same Python script (`../../benchmark/scripts/cmd-cpu.sh`, `results/fc-cpu512-guest.txt`):

| operation | guest | host | ratio |
|---|---|---|---|
| first-touch page fault, fresh anonymous memory | 4.43 µs/page | 2.06 µs/page | **2.15×** |
| second pass over memory the guest had touched | 1.88 µs/page | 1.99 µs/page | 0.94× |
| `fork` + `exec` of `/bin/true` | 0.44 ms | 0.62 ms | not comparable (host root is `overlayfs`) |
| `getpid` through Python | 627 ns | 626 ns | 1.00× |

What the extra 2.55 µs per guest first touch is: the guest's own fault (1.88 µs, the second-pass figure) plus, across a VM exit, the **host's own first-touch fault** on Firecracker's anonymous guest-memory mapping, which allocates and zeroes the page (most of the host's 2.06 µs). The page is zeroed twice, once by the host and once by the guest kernel. The first draft called the whole difference "the EPT violation"; the exit is only part of it. Neither side's transparent-huge-page state was recorded (`fc-cpu512-guest.txt` records neither), and the guest ran kernel 6.1 against the host's 6.8.

The kernelet's first touch is the native fault plus its share of the host's zeroing at grant (D55: 50–100 µs per 2 MiB grain, 0.1–0.2 µs per page amortized) on top of `zeroed(true)` in its own allocator: about **2.2 µs**, *estimated*, twice zeroed as well but without the exit. System calls that do not exit cost the same in both, as the `getpid` row shows.

## Gain

For an agent whose active CPU is dominated by process creation and first-touch faults (shell tool calls, test runs, builds), a VM without hugepage-backed guest memory pays about 2.0× on every new page (4.43 against 2.2 µs); for one that waits on a model API, almost nothing. Taking the fraction `f` of active CPU spent in first-touch faults as **0.1–0.3 [unverified]**, `c_active(VM) ≈ c_active(kernelet) × (1 + 1.0 f)`, so the CPU-bound density ratio is **1.1–1.3× against a VM without hugepage-backed memory**. At technique parity the VM's memory is 2 MiB-backed (Firecracker supports it), the host-side populate is one fault per 512 pages, and the residual is the exit plus the double zeroing: the honest range is **1.0–1.1×**, *estimated*, until the host side is rerun with `MAP_POPULATE` or hugetlbfs backing to bracket it.

Two terms the first draft counted are dropped. "An exit per I/O completion" was neither measured nor cited: a Firecracker I/O costs an ioeventfd exit and an irqfd injection (no exit at all with posted interrupts), while a kernelet I/O on the Devices page costs a device-thread wakeup, a `raise_irq` plus worker wakeup, two register crossings and a park/unpark; which is cheaper is **[unverified] in both directions**. And the per-wake scheduling cost (a vCPU thread wake against a job delivery) is unmodeled.

## Evidence

- Measured: the table above, one host, one guest kernel configuration, THP state unrecorded on both sides.
- Published: the Blueprint's User-mode page (`src/blueprint/design/virtualizing-ostd/user-mode.md`) cites an earlier prototype's cold page fault at 10,345 cycles against 9,791 native, within 6 %; that is a figure about a prior prototype, not about this design, and the Paper's Evaluation page states that no measurement of Asterinas Kernelets exists.

## Isolation

None.

## Changes to the Blueprint

None.
