# The comparison, and the choice

*Twenty designs, five of them whole modes. This page puts them side by side against the four things Linux mode was failing, says which one to build, and says plainly what the exploration did not achieve.*

## The scoreboard

The four rows are the three properties the boundary owes a tenant, plus the invariant behind the third. *Parity* means the property holds exactly as well as it does on the host we wrote, which is the honest bar — the Design chapter's own containment is bounded at service-call depth zero too.

| | safety | fault containment | fairness | termination (I7) |
|---|---|---|---|---|
| **Linux mode as chapter 13 has it** | short: three entries unhooked | absent | absent by default | absent |
| **Conservative restoration** | restored | parity | narrowed | parity, by revoke |
| **Supervisor alias** | as conservative | as conservative | as conservative | as conservative |
| **Per-instance module** | as conservative | restored | as conservative | as conservative |
| **Self-hosted carriers** | as conservative | parity | weaker per thread | bounded and targetable |
| **Guest ring 0** | deleted, not closed | **restored** | restored | **restored outright** |

And what each asks for:

| | patch | exports | boot setting | build option | density |
|---|---|---|---|---|---|
| chapter 13 today | ~25 lines, one architecture, one entry of four | 5 | yes | yes | thousands |
| conservative | ~15 lines, generic layer, every entry, four architectures | 3 | none | none | thousands |
| supervisor alias | + ~15 lines | 3 | none | none | thousands |
| per-instance module | none | 0 | none | none | **56 per machine** |
| carriers | conservative's, plus reaching into three structures | 3 | none | none | thousands |
| guest ring 0 | a hypervisor | 2 | none | none | thousands, minus 1.20× on every memory access |

## What the exploration actually established

**Four of the chapter's limitations were not limitations.** A fault in kernelet code is recoverable with an exported interface; the legacy virtual system-call page is closed by a seccomp filter rather than a boot setting; the modern one is closed by not mapping it; and a kernelet's pinned threads can join a processor set after all. A fifth, the tenant's process lifecycle, has a supported extension point that Linux has exported since binary-format handlers became loadable.

**Two of the chapter's numbers were wrong in the direction that matters.** The module region is 1008 MiB rather than 1520 MB on a kernel anyone ships. And the framework's own exception table holds absolute addresses, so the Design chapter's region table put a section full of addresses in the shared, address-free region, where the build audit would have rejected it.

**Two designs improve the host the book actually specifies.** Indexing frame metadata by section rather than by raw physical address moves the density cap from about two thousand kernelets per terabyte to about sixty thousand, and stops it growing with the machine, on both hosts. And the supervisor alias would let Asterinas enable a hardware protection it currently leaves off entirely, at a measured 0.92 cycles per access against 38 for the alternative.

**One limitation got worse under inspection.** A tenant enters its kernelet by a signal and by a synchronous exception as well as by a system call, and the chapter counts neither. The answer costs no patch, but it had to be found: blocking those signals does not work, because Linux unblocks a forced signal before delivering it, which turns a trap into a kill.

## The choice

**Build the conservative restoration**, with two components taken from designs that lost.

It is the mode to adopt because it asks Linux for less than chapter 13 asks today and delivers more: one gate in the generic entry layer instead of four hooks in one architecture, three exports instead of five, no boot setting and no build option. It restores safety, brings fault containment and termination to parity with the host we wrote, and narrows fairness to a residue that is genuinely irreducible, being work a tenant induces in the host that Linux will not charge to it.

The two components to take from elsewhere are **section-indexed frame metadata**, because it retires the worst number in the previous chapter on both hosts for one cache-resident load, and **self-relative exception tables**, because the Design chapter is inconsistent without them and because they are the precondition for everything Linux might later do with a kernelet's own fixups.

Two more are next rather than now. The **supervisor alias** is measured and nearly free, and its value to Asterinas is larger than its value to Linux, but it takes the branch of a conflict that costs the tenant direct input and output, and its second-translation cost is unmeasured. The **carriers** design has the highest ceiling of anything here, because it is the only one that makes Linux mode and Asterinas mode the same design rather than two implementations of one interface; but it is a layer on top of the conservative mode, its switch costs 291 nanoseconds, and two cheap tests should come before any of it.

## What this does not achieve, stated plainly

**No design restores all three properties at a cost this chapter can defend.** Exactly one restores all three — guest ring 0 — and it does so by giving up kernel-mode execution, adding a hypervisor, and taxing every memory access of every tenant by twenty percent at a realistic working set. That is a real answer to "what would all three cost", and the answer is "a different book".

So the exit condition this exploration set itself was not met, and that is the finding rather than a failure of it. Fault containment and termination on Linux are **parity with Asterinas, not restoration**, because both hosts bound containment at service-call depth zero. The residue is a kernelet that misbehaves *inside* a service call, which neither host can stop, and which only a hardware timer or a kill point inside Linux would fix.

**And one thing could still kill the mode that won.** Its model page table and its seat put locks on the same hot path, and they multiply. No first-wave agent could see it, because each saw one cluster. It is measurable on the prototype that already exists, and it has not been measured.
