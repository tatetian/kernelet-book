# The comparison, and the choice

*Twenty designs were explored, fifteen against one cluster of limitations each and five as whole modes; one of the fifteen is recorded as a paragraph rather than a section, because the corrections overtook it. This page puts the rest side by side against the four things Linux mode was failing, says which one to build, and says plainly what the exploration did not achieve.*

## The scoreboard

The four rows are the three properties the boundary owes a tenant, plus the invariant behind the third. *Parity* means the property holds exactly as well as it does on the host we wrote, which is the honest bar — the Design chapter's own containment is bounded at service-call depth zero too.

| | safety | fault containment | fairness | termination (I7) |
|---|---|---|---|---|
| **Linux mode, before this chapter's corrections** | short: three entries unhooked | absent | absent by default | absent |
| **Conservative restoration** | restored | parity | narrowed | parity, by revoke |
| **Supervisor alias** | as conservative | as conservative | as conservative | as conservative |
| **Per-instance module** | as conservative | restored | as conservative | as conservative |
| **Self-hosted carriers** | as conservative | parity | weaker per thread | bounded and targetable |
| **Guest ring 0** | restored, by deletion | **restored** | restored | **restored outright** |

The first row of each table is the mode as it stood when the exploration began. Its corrections are already folded into that chapter, which is why it no longer reads that way.

And what each asks for:

| | patch | exports | boot setting | build option | density |
|---|---|---|---|---|---|
| [Linux as the host](../linux-mode/index.md), before these corrections | ~25 lines, one architecture, one entry of four | 5 | yes | yes | thousands |
| conservative | ~15 lines, generic layer, every entry, four architectures | 3 | none | none | thousands |
| supervisor alias | + ~15 lines | 3 | none | none | thousands |
| per-instance module | none | 0 | none | none | **56 per machine** |
| carriers | conservative's, plus reaching into three structures | 3 | none | none | thousands |
| guest ring 0 | a hypervisor | 2 | none | none | thousands, minus 1.20× on every memory access |

## What the exploration actually established

**Four of the chapter's limitations were not limitations.** A fault in kernelet code is recoverable with an exported interface; the legacy virtual system-call page is closed by a seccomp filter rather than a boot setting; the modern one is closed by not mapping it; and a kernelet's pinned threads can join a processor set after all. A fifth, the tenant's process lifecycle, has a supported extension point that Linux has exported since binary-format handlers became loadable.

**Two of the chapter's numbers were wrong in the direction that matters.** The module region is 1008 MiB rather than 1520 MB on a kernel anyone ships, because the region is what is left after a kernel image that reserves twice as much when address randomization is on. And the framework's own exception table holds absolute addresses, so the Design chapter's region table put a section full of addresses in the shared, address-free region, where the build audit would have rejected it.

**Two designs improve the host the book actually specifies.** Indexing frame metadata by section rather than by raw physical address moves the density cap from about two thousand kernelets per TiB of physical span to about sixty thousand (*estimated*, from the region sizes), and stops it growing with the machine, on both hosts. And the supervisor alias would let Asterinas enable a hardware protection it currently leaves off entirely, at a measured cost indistinguishable from an ordinary kernel access, against 38 cycles for the alternative.

**One limitation got worse under inspection.** A tenant enters its kernelet by a signal and by a synchronous exception as well as by a system call, and the chapter counts neither. The answer costs no patch, but it had to be found: blocking those signals does not work, because Linux unblocks a forced signal before delivering it, which turns a trap into a kill.

## The choice

**Build the conservative restoration**, with two components taken from designs that lost.

It is the mode to adopt because it asks Linux for less than chapter 13 asks today and delivers more: one gate in the generic entry layer instead of four hooks in one architecture, three exports instead of five, no boot setting and no build option. It restores safety, brings fault containment and termination to parity with the host we wrote, and narrows fairness to a residue that is genuinely irreducible, being work a tenant induces in the host that Linux will not charge to it.

The two components to take from elsewhere are **section-indexed frame metadata**, because it retires the worst number in the previous chapter on both hosts for one cache-resident load, and **self-relative exception tables**, because the Design chapter is inconsistent without them and because they are the precondition for everything Linux might later do with a kernelet's own fixups.

The **supervisor alias** goes in the same increment, gated on one measurement. The rule that promoted the other two was that a fix helping both hosts beats one helping Linux, and by that rule the alias selects itself: it is the only thing in the exploration that would let Asterinas enable a hardware protection it leaves off today, at a cost indistinguishable from an ordinary kernel access against 38 cycles for the alternative. The gate is its translation-buffer cost, which is unmeasured and which the same harness that measured the second-level translation cost of guest ring 0 can produce in a day. Its other debit is real and should be stated as its own argument rather than borrowed from a neighbor: the alias is a translation and not an access, so a page the kernelet has not already supplied does not fault in through it, which is why it is correct only while the kernelet owns every one of its tenant's pages.

The **carriers** design is next rather than now. It has the highest ceiling of anything here, because it is the only one that makes Linux mode and Asterinas mode the same design rather than two implementations of one interface; but it is a layer on top of the conservative mode, a switch costs 291 nanoseconds, and two cheap tests should come before any of it.

## What this does not achieve, stated plainly

**No design restores all three properties at a cost this chapter can defend.** Exactly one restores all three — guest ring 0 — and it does so by giving up kernel-mode execution, adding a hypervisor, and taxing every memory access of every tenant by twenty percent at a realistic working set. That is a real answer to "what would all three cost", and the answer is "a different book".

So the exit condition this exploration set itself was not met, and that is the finding rather than a failure of it. Fault containment and termination on Linux are **parity with Asterinas, not restoration**, because both hosts bound containment at service-call depth zero. The residue is a kernelet that misbehaves *inside* a service call, which neither host can stop, and which only a hardware timer or a kill point inside Linux would fix.

That cuts the other way too, and the previous chapter should own it. If containment is bounded at depth zero on **both** hosts, then what that chapter recorded as a Linux deficiency was in part the design's own bound, attributed to the host. Decision D81's "fault containment does not hold in Linux mode" was not merely overtaken by the die notifier; it was wrong in its framing when it was written, because the property it says Linux loses was never held at depth one anywhere.

**And one thing could still kill the mode that won, though not the thing this page first named.** The stated risk was that the model page table's cursor lock and the seat's replica lock multiply. On inspection that is a tail: two threads contend only when their buffers fall under the same leaf table, which is uncommon for per-thread buffers and certain for a shared array. And the seat's real cost is not a lock at all but a cap, since a tenant's in-kernel concurrency is limited to its virtual-CPU count, which is defensible and is a thing a tenant can observe.

The **certain** cost is the walk itself, which this chapter prices as an aside: a page-table walk on every system call that carries a buffer, against a serviced call measured at 39 nanoseconds. A cold walk is four potentially dependent misses, which is the same order as the entire crossing it is attached to. That needs no prototype to bound — it is arithmetic over miss counts and a user-space loop — and it should be measured before either lock.

Which changes the sequencing above for a better reason than the one given. The supervisor alias does not merely help the other host: it **removes the winner's largest certain cost**, by turning the walk into an addition. Measure the walk first; if it is cheap the risk is a tail, and if it is not, the alias stops being an increment and becomes part of the design.

There is a second-order result in that. The carriers design, ranked after the winner, *reduces* exactly this risk: it drops the number of page-table cursors held at once from every tenant task the host is running to the number of virtual CPUs. So the thing most likely to kill the chosen mode is mitigated by the thing ranked next, which is an argument for measuring the two together rather than in sequence.
