# Linux as the host (WIP)

*A second host for the same kernelets. The Design chapter assumes the host kernel is Asterinas; this chapter asks whether Linux can host kernelets instead, finds nothing that rules out a patched Linux, and says exactly what it costs. **No kernelet has been built or run, on either host.** What was built and measured here is the mechanism each claim turns on; every other Linux fact is cited to Linux's own source with a link. The chapter also revises two decisions in the Design chapter and withdraws two assumptions, because the mechanism that makes Linux mode possible is better in both modes.*

## Why ask

[vOSTD](../overview/terminology.md), the build of the framework a kernelet is compiled against, virtualizes an **API**, not a machine. A kernelet calls a table of functions and never touches hardware. Nothing in that arrangement says who implements the table. If the answer can be "Linux", two things follow.

**For the research.** The claim stops being *we built a second personality of our own kernel* and becomes *the boundary is the API, and the host beneath it is replaceable*. A mechanism that works on two unrelated kernels is a mechanism, not a coincidence.

**For adoption.** The objection to kernelets is not the idea; it is the deployment. Kernelets ask an operator to put a young kernel in the most privileged position on the machine. Linux mode removes that ask. An operator keeps the kernel they already run, and gains sandboxes whose kernel code is safe Rust.

That does not make Linux mode the better design. Of the three properties the boundary owes a tenant, Linux weakens all three, and each is argued where it arises later:

- **Safety.** Even patched, the kernelet is not quite the tenant's only system-call surface: three of the four entry points are unhooked, and Linux's own trusted base is now inside the boundary ([the tenant](tenant.md)). Both of those have answers in [Alternative designs](../alternatives/index.md), where one hook in the generic entry layer covers every entry.
- **Fault containment.** A fault in kernelet code is a Linux oops rather than a contained kill, unless a module catches it — which one can, and [Alternative designs](../alternatives/index.md) shows how ([five places](not-as-assumed.md)).
- **Fairness.** A runaway kernelet cannot be stopped, because Linux will not stop a task in kernel mode, and a tenant's pages are charged to nobody by default.

So the two modes are a real choice and not a ladder. Linux mode is what an operator can deploy on the kernel they already run; Asterinas mode is what the design is specified against, and the difference between them is a list of named properties rather than a feeling about maturity.

## What this chapter concludes

**Nothing found here rules out a patched Linux.** Both qualifications are earned. *Patched*: an unmodified Linux is ruled out, for reasons of function rather than speed — without the patch a kernelet cannot intercept a tenant past its first process. *Nothing found*: no kernelet has run, on either host.

One configuration is not yet settled and is deliberately not in that sentence. A kernel built with **type-checked indirect branches** rewrites its own call sites and function preambles to compare a hash of each function's type, and a kernelet image arrives without what that rewrite needs. It is a hardening option rather than a property of Linux: it requires the kernel to be built with a compiler that x86-64 distributions do not use for it, it can be turned off at boot, and the kernelet side may well be able to satisfy it — the compiler half is [measured](evidence.md) to work, and Linux already requires its two compilers to agree on the hash for a given prototype. It is recorded as assumption A19, and it belongs there rather than in a conclusion.

Three things had to be true. Two were tested on a kernel built and booted for the purpose; the third is an argument from Linux's own interfaces, cited page by page:

1. **Many kernelets can share one kernel address space.** The Design chapter used to give each kernelet its own kernel page table, because each was linked at fixed addresses. Linux cannot do that: its kernel half is shared by every process by construction. The fix is to make the kernelet image position-independent and load each instance at a different offset. One physical copy of the text serves every instance, and each instance's data is selected by the processor's own program-counter-relative addressing, with no register, no table and no lookup. This was [measured](evidence.md): four instances, one physical text page, each call returning its own instance's data.

2. **The tenant's system calls can reach the kernelet, and only with a patch.** Linux offers an out-of-tree component no way to answer a system call in the kernel, so the chapter first looked for a way without one, and there is not one. [Syscall User Dispatch](tenant.md) can divert a call to a stub in user space, but Linux clears it at every `fork` and every `exec`, so only a tenant's first thread is ever intercepted; and there is no stub trick that closes it, because the child's first instruction runs before anything in user space could re-arm the setting. What dispatch does give is a **measurement**: at least **885 ns** added to every call, which is the floor for any interception that goes through user space. The per-task hook a small patch adds costs nothing measurable against a floor of 44 ns in the same guest. So the patch is not the fast tier of two. It is the only tier, and what it buys first is that the kernelet is the tenant's boundary at all.

3. **Most of the rest maps onto ordinary Linux.** Kernelet tasks are kernel threads, tenant memory is a virtual memory area whose fault handler is the kernelet's, grains are pages from Linux's allocator addressed through its direct map, and a virtual interrupt is a wakeup. None of that needs a patch. What does not map is enumerated rather than glossed: the kernel proper cannot touch its tenant's memory directly at all, and the kernel-mode fault path, the per-CPU and preemption model, the tenant's process lifecycle and the virtual system-call page each need an answer the design does not have ([five places](not-as-assumed.md), [what differs](what-differs.md)). None of this was built; the third point is argued from Linux's interfaces, not demonstrated.

One thing is needed before any of it: an out-of-tree module **cannot make memory executable at an address it chooses**. `vmap()` strips the execute permission, `execmem_alloc()` is not exported, and no permission setter is exported either. So Linux mode needs `set_memory_rox` exported — and `set_memory_rw` with it, because the first call also makes those frames read-only in the host's direct map and they cannot be given back until that is undone. Three more are wanted for a complete module. The [evidence](evidence.md) page lists them with what each one is for.

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

- **Exports, a patch, and a build option.** A pair of exported symbols before anything runs and three more for a complete module; a kernel built with the notifier machinery the alias rule needs, which any kernel with virtualization support already has; and the system-call hook, which is required rather than optional. The boot setting this list used to carry is withdrawn, because a seccomp filter closes what it was for. [Alternative designs](../alternatives/index.md) withdraws the build option too, and two of the exports, by keeping the kernelet's own page table as a model rather than maintaining a second map.
- **One hardening option, not yet settled.** Where the host's own build enforces type-checked indirect branches, a kernelet's entry functions must carry preambles the host's compiler would accept, and nothing in this design produces them yet; the first call into a kernelet would trap. The option needs a compiler x86-64 distributions do not use for the kernel and can be turned off at boot, so this excludes a configuration rather than a class of machine. Assumption A19.
- **Linux's own maturity is now in the trusted base.** The operator keeps their kernel, and keeps its bugs. Kernelets stop the tenant's *kernel* from being the attack surface; they do not make Linux smaller.
- **The three weakened properties above**, which are the reason the two modes are a choice rather than a ladder.
- **A user-access path the framework has to grow.** On a host that enables the processor's supervisor-access check — Linux does, Asterinas does not — the framework's copy routines need a second body, because reaching a tenant's memory through a *user* mapping is refused. Bracketing the access is a few instructions and handles every valid address, including one that has to be faulted in. What it does not handle is a *bad* address, and those are routine here by design, since this kernel validates a tenant's pointers by faulting on them rather than by checking them. The complete answers are small too: reach the memory through a mapping that is not marked user, or teach Linux's fixup search about the kernelet's table, which is fifteen lines and the same patch containment wants. It is a change inside the framework, not a barrier, and the Design chapter never named it because Asterinas leaves the check off.
- **Open design, not just open engineering.** How a kernelet's processes map onto Linux tasks, who owns the tenant's signals, how per-CPU data is selected on a task Linux schedules, and how the virtual system-call page is handled are not answered in this chapter.

## In this chapter

- [Background: the Linux this chapter needs](background.md) — every Linux concept used later, defined before use, for a reader who has never worked on Linux.
- [One address space, many kernelets](one-address-space.md) — the position-independent scheme, why it is needed, what it costs, and the Design-chapter decisions it revises.
- [The endovisor as a Linux module](endovisor.md) — loading a kernelet, its memory, its tasks, its interrupts.
- [The tenant: user mode and system calls](tenant.md) — the hard part: what a fault handler can and cannot supply, four candidate mechanisms, and the measured choice.
- [Five places where the host does not behave as the design assumed](not-as-assumed.md) — termination, fault containment, tenant memory, the kernel stack, and per-CPU data, collected in one place.
- [What differs between the two hosts](what-differs.md) — the item-by-item tables, which are this chapter's central claim.
- [Evidence](evidence.md) — what was built, what was measured, and what is still argued rather than shown.
