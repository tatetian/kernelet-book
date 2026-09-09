# C14: CPU per operation

**Status:** adopted as a sensitivity on the CPU bound; the workload fraction it applies to is unverified. **Depends on kernelets:** yes. **Acts on:** `c_active`, the CPU an active sandbox consumes, which is the binding resource at technique parity.

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

The first-touch cost is the EPT violation on a guest-physical page the host has not backed yet, serviced across a VM exit, on top of the guest's own fault; once the guest memory is backed, guest faults cost what native faults cost. The Paper's prototype measured a cold page fault at 10,345 cycles in the kernelet's guest against 9,791 native, within 6 %, so a kernelet's first touch is the native 2 µs, not the VM's 4.4. System calls that do not exit cost the same in both.

## Gain

For an agent whose active CPU is dominated by process creation, first-touch faults and I/O completions (shell tool calls, test runs, builds), the VM pays the EPT-violation tax on every new page and an exit per I/O completion; for one that waits on a model API, almost nothing. Taking the fraction `f` of active CPU spent in first-touch faults and exit-bearing I/O as **0.1–0.3 [unverified]**, `c_active(VM) ≈ c_active(kernelet) × (1 + 1.15 f)`, so the CPU-bound density ratio at technique parity is **1.1–1.35×**. This is the honest residual advantage where every memory technique is available to both sides.

## Evidence

- Measured: the table above, one host, one guest kernel configuration, without huge pages on either side (Firecracker's huge-page guest memory would cut the EPT cost by making first touches 2 MiB at a time, at the price of restore granularity).
- Published: the Paper's prototype fault measurement.

## Isolation

None.

## Changes to the Blueprint

None.
