# Linux as the host

*A second host for the same kernelets. The Design chapter assumes the host kernel is Asterinas; this chapter asks whether Linux can host kernelets instead, finds nothing that rules it out, and says exactly what it costs. **No kernelet has been built or run, on either host.** What was built and measured here is the mechanism each claim turns on; every other Linux fact is cited to Linux's own source with a link. The chapter also revises two decisions in the Design chapter and withdraws two assumptions, because the mechanism that makes Linux mode possible is better in both modes.*

## Why ask

vOSTD virtualizes an **API**, not a machine. A kernelet calls a table of functions and never touches hardware. Nothing in that arrangement says who implements the table. If the answer can be "Linux", two things follow.

**For the research.** The claim stops being *we built a second personality of our own kernel* and becomes *the boundary is the API, and the host beneath it is replaceable*. A mechanism that works on two unrelated kernels is a mechanism, not a coincidence.

**For adoption.** The objection to kernelets is not the idea; it is the deployment. Kernelets ask an operator to put a young kernel in the most privileged position on the machine. Linux mode removes that ask. An operator keeps the kernel they already run, and gains sandboxes whose kernel code is safe Rust.

That does not make Linux mode the better design. Of the three properties the boundary owes a tenant, Linux weakens all three, and each is argued where it arises later:

- **Confinement.** The kernelet stops being the tenant's only system-call surface unless Linux is patched, so on an unpatched kernel the real boundary is the container's ([the tenant](tenant.md)).
- **Fault containment.** A fault in kernelet code is a Linux oops rather than a contained kill, and the routine first-touch faults the kernel proper depends on cannot be recovered at all without a redesign of that path ([the tenant](tenant.md)).
- **Fairness.** A runaway kernelet cannot be stopped, because Linux will not stop a task in kernel mode, and a tenant's pages are charged to nobody by default.

So the two modes are a real choice and not a ladder. Linux mode is what an operator can deploy on the kernel they already run; Asterinas mode is what the design is specified against, and the difference between them is a list of named properties rather than a feeling about maturity.

## What this chapter concludes

Nothing found here rules Linux out. Three things had to be true. Two were tested on a kernel built and booted for the purpose; the third is an argument from Linux's own interfaces, cited page by page:

1. **Many kernelets can share one kernel address space.** The Design chapter gives each kernelet its own kernel page table, because each is linked at fixed addresses. Linux cannot do that: its kernel half is shared by every process by construction. The fix is to make the kernelet image position-independent and load each instance at a different offset. One physical copy of the text serves every instance, and each instance's data is selected by the processor's own program-counter-relative addressing, with no register, no table and no lookup. This was [measured](evidence.md): four instances, one physical text page, each call returning its own instance's data.

2. **The tenant's system calls can reach the kernelet.** Linux offers an out-of-tree component no way to do this in the kernel, so the answer has two tiers. Without touching Linux, [Syscall User Dispatch](tenant.md) turns each tenant call into a signal and a short trip through user space, which added at least **885 ns** to each call in the test guest. With a per-task hook added by a small patch, reaching the servicer cost nothing measurable at all. Both were measured in the same guest in the same run, whose floor is far lower than a production kernel's, so it is the overheads and not the ratio between them that carries ([the tenant](tenant.md)). The patch matters for a reason larger than either number: without it the tenant can still reach Linux's own system calls, so the kernelet is not its boundary.

3. **Most of the rest maps onto ordinary Linux.** Kernelet tasks are kernel threads, tenant memory is a virtual memory area whose fault handler is the kernelet's, grains are pages from Linux's allocator addressed through its direct map, and a virtual interrupt is a wakeup. None of that needs a patch. What does not map is enumerated rather than glossed: the kernel-mode fault path, the per-CPU and preemption model, the tenant's process lifecycle, and the virtual system-call page ([what differs](what-differs.md)). None of this was built; the third point is argued from Linux's interfaces, not demonstrated.

One thing is needed unconditionally: an out-of-tree module **cannot make memory executable at an address it chooses**. `vmap()` strips the execute permission, `execmem_alloc()` is not exported, and no permission setter is exported either. Linux mode therefore needs `set_memory_rox` exported, which is a one-line change; a complete Linux mode wants four, listed on the [evidence](evidence.md) page with what each one is for.

## What this is not

Running one kernel's code under another kernel is an old idea, and Linux mode is not new in that respect. It is worth saying which old idea it is closest to, and where it differs, so the contribution is not read as larger than it is.

**Kernel code in a host kernel.** [Rump kernels](https://rumpkernel.org/) and the [Linux Kernel Library](https://github.com/lkl/linux) take a kernel's subsystems and run them somewhere else, usually a user-space process. The shape is the same: an operating system's code above a small, portable substrate. Two things differ. Those projects move code *out* of the kernel and reach user space; a kernelet stays in kernel mode, which is where its performance comes from. And their substrate is hand-written for each environment, whereas vOSTD is the same API the unmodified kernel already compiles against.

**Sandboxes that service a tenant's system calls.** [gVisor](https://gvisor.dev/docs/architecture_guide/platforms/), [Gramine](https://gramineproject.io/) and User-Mode Linux all put a kernel personality between the tenant and the host, and gVisor's current platform intercepts calls in a way whose shape is the one measured here as the no-patch path ([the tenant](tenant.md) states the difference exactly). What differs is where the personality runs: theirs in user mode, entering the kernel once more per call, and a kernelet's in kernel mode, which is what the patched hook's measurement is about. [Dune](https://dl.acm.org/doi/10.5555/2387880.2387913) gives a user process privileged hardware features for a related reason by a different route.

**Mutually distrusting components at full privilege in one address space.** This is the closest prior art for what a host full of kernelets actually is, and it is the driver-isolation line: [Nooks](https://dl.acm.org/doi/10.1145/945445.945454) wrapped untrusted drivers inside the kernel and recovered from their failures, and the later work on language-enforced isolation carried the same idea with types rather than hardware. That line is where "separation by discipline rather than by page tables" was shown to be workable, and where its failure modes were catalogued. Kernelets differ in what the discipline is — a whole kernel written in safe Rust above a narrow API, rather than a wrapper around an existing driver — and in what is isolated, which here is a tenant rather than a device.

**Many instances of one text in one address space.** Shared libraries, `dlmopen`, thread-local storage and per-CPU variables all solve this, and [One address space, many kernelets](one-address-space.md) says what is different about solving it from the program counter.

**Hardware that could separate kernelets.** Protection keys for supervisor pages are the mechanism people reach for, and two facts are worth stating before anyone counts on them. Linux has no support for them at all: the merged work covers user-space keys only. And the hardware offers sixteen keys, while every instance of a kind executes the same shared text and would therefore have to share one — which buys "kernelet data versus the rest of the kernel", not one instance versus another among thousands. It is not a fix that is one patch away.

So the contribution is not "kernel code can be virtualized" and not "one text can serve many instances". It is that the boundary can be an **API the kernel already compiles against**, that the host beneath it is replaceable, and that on Linux the replacement costs a handful of exported symbols and one patch whose absence is a security problem rather than a slowdown.

## What it costs, stated once

Linux mode is not free, and this chapter does not pretend otherwise:

- **Exports, a patch, and a boot setting.** A pair of exported symbols before anything runs, two more for a complete module, a kernel command line that turns off the legacy virtual system-call page, and the system-call hook — a separate, larger patch, and the thing that makes the kernelet the tenant's boundary.
- **Linux's own maturity is now in the trusted base.** The operator keeps their kernel, and keeps its bugs. Kernelets stop the tenant's *kernel* from being the attack surface; they do not make Linux smaller.
- **The three weakened properties above**, which are the reason the two modes are a choice rather than a ladder.
- **A crossing where there was none.** The kernel proper's copies to and from tenant memory must become service calls, because Linux's fault handler cannot recover them. The cost is unmeasured and it is the chapter's largest performance question.
- **Open design, not just open engineering.** How a kernelet's processes map onto Linux tasks, who owns the tenant's signals, how per-CPU data is selected on a task Linux schedules, and how the virtual system-call page is handled are not answered in this chapter.

## In this chapter

- [Background: the Linux this chapter needs](background.md) — every Linux concept used later, defined before use, for a reader who has never worked on Linux.
- [One address space, many kernelets](one-address-space.md) — the position-independent scheme, why it is needed, what it costs, and the Design-chapter decisions it revises.
- [The endovisor as a Linux module](endovisor.md) — loading a kernelet, its memory, its tasks, its interrupts.
- [The tenant: user mode and system calls](tenant.md) — the hard part: four candidate mechanisms, the measured choice, and four things Linux will not do.
- [What differs between the two hosts](what-differs.md) — the item-by-item tables, which are this chapter's central claim.
- [Evidence](evidence.md) — what was built, what was measured, and what is still argued rather than shown.
