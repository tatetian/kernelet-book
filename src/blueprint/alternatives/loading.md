# Loading, and the hardware underneath

*Three designs against the constraints that decide how many kernelets a machine can hold and whether it can hold any at all. One of them retires the sharpest number in the previous chapter, on both hosts. One of them settles an assumption that could have excluded a whole class of kernel. The third stops asking Linux for permission and writes the page-table entries itself.*

## Frame metadata that does not scale with the machine {#metadata}

*Attacks:* the density cap. *Helps:* **both hosts**.

The previous chapter's sharpest number is that the per-instance frame-metadata regions cap a machine at about two thousand kernelets per terabyte of physical span, on four-level paging, on either host. That cap is not a property of frame metadata. It is a property of one line of arithmetic: the framework finds a frame's record by scaling the raw physical address, so the region must be able to address every frame the kernelet might ever be granted, which on Linux is the whole machine.

Replace the flat index with a two-level index over a coarse section of physical memory — which is exactly how Linux finds its own per-page records when it will not pay for a flat array. The region stops being sized by the machine and starts being sized by policy. The cap moves from about two thousand per TiB of physical span to about sixty thousand (*estimated*, from the region sizes), and more importantly it stops growing with the machine.

**What it costs.** One extra load on the two operations that sit on every page fault, taking a frame's reference and dropping it. That load should be cache-resident, and whether it is can be measured in a user-space loop rather than in a kernel.

**What it asks of the framework.** Less than it appears. Both functions are internal to the framework, so no public interface moves.

**Verdict.** Promising, and the first of these three to build. The smallest change here, it retires the chapter's worst number, and it helps the host we wrote as much as the host we do not.

## The kind is a module {#kind-is-a-module}

*Attacks:* the assumption that could exclude a class of host. *Helps:* Linux only.

The open question about type-checked indirect branches is not whether a kernelet's text can carry the right markers, which was measured, but whether it can carry the tables the kernel's own rewriter needs, and match the hash the host's compiler computes for a prototype.

Build the kind's image with the kernel's own settings, run the kernel's own build-time checker over it, ship the resulting tables inside a module for the **kind**, and let the module loader apply the rewrite with the running kernel's seed. The rewrite is keyed by type rather than by address, so one rewritten copy per kind serves every instance.

And the part of the assumption that looked hardest is already a Linux requirement. Linux makes its Rust support depend on its two compilers agreeing on the type tag for a prototype, and says so in as many words. Confirming it costs an hour and no kernel: compile one function with each toolchain and compare two constants.

**What it costs.** A build of the kind's image with the host kernel's own settings and tooling, which couples the image to the host's compiler configuration in a way nothing else in the design does.

**Verdict.** Promising, and it should be resolved before anything else is built, because it is the only open item that can rule out a whole class of host.

## The endovisor writes its own page-table entries {#own-entries}

*Attacks:* the image's mapping, the mandatory exports, the machine-wide flush, and device addressing. *Helps:* Linux only.

The chapter takes what Linux offers and pays what Linux charges: small-page mappings for text every sibling shares, a permission call that interrupts every processor, and two exported symbols it cannot start without. This design takes a large-page-aligned range from an exported allocator, finds the entry that describes it with another exported call, and re-points that entry at the kind's shared text as a single large-page mapping with the permissions it wants.

A thousand small-page translations per instance become two. Both of the mandatory exports disappear, because nothing has to change a permission after the fact. Grains come from a boot-reserved pool through the host's own device-memory interface, and the grant is identity-mapped through the host's translation unit so that a device address is a physical address again, which is the one limitation the chapter leaves unaddressed on *both* hosts.

**What it costs.** The endovisor writes kernel page-table entries directly, which is trusted code of a kind the design has so far avoided, and it depends on the host's internal layout in a way that an interface would not.

**Verdict.** Needs work, and the mapping half is the strong part. Writing an entry that Linux believes it owns is the kind of thing that works until a release changes underneath it.
