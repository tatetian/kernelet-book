# API Virtualization

If a kernel's services reach the world only through the framework's API, then a tenant's own kernel instance needs only an implementation of that API whose global effects are confined to the instance. We build that implementation from the framework itself. OSTD is compiled a second time, under a `kernelet` build configuration, and the kernel proper is compiled, unmodified, against that build. Under the configuration, every public item of the framework is one of three things.

- **Identical.** An operation whose effect is local to the caller keeps its implementation: user-memory copies, spin locks, the clock, the page-table cursor over the caller's own address space.
- **Virtualized.** An operation that touches machine-wide state keeps its name and signature and gets a per-instance implementation over the endovisor: task creation and waiting, device registers and interrupt lines, DMA, frame allocation, timers, logging.
- **Absent.** An operation a tenant must never have is not defined: interrupt masking, inter-processor interrupts, the kernel page table, machine halt. Reaching for one does not compile.

Which of the three an item is can be read from the framework's own source, so the virtualized API cannot drift from the API it virtualizes; and the kernelet build of the framework may use `unsafe` where the framework does, so the virtualized implementation is not limited to what safe Rust can express. Only the kernel proper is held to `forbid(unsafe_code)`.

The kernel proper and its framework build are linked into an ELF of their own, the *kernelet image*, separate from the host kernel's. It has no undefined symbols. Its single entry point receives a table of `extern "C"` function pointers, the *endovisor ABI*, through which every virtualized operation reaches the host kernel, and returns a table of the kernelet's own entry points. The two ELFs are produced by one build and combined into one boot image; nothing is loaded from outside the image at run time, so that the kernel proper contains no `unsafe` is attested by the build that produced the image, not inferred from an object file. The instance is a *kernelet*. What sits beneath the ABI is the *host kernel*: the framework in its host build, the physical drivers, the scheduler, the allocators, and the *endovisor*, the component that implements the ABI and creates, mediates and destroys kernelets. The host kernel is the trusted computing base.

## Why this is a different boundary {#why}

The table below sets the three boundaries side by side. Two properties separate API virtualization from OS virtualization. A kernelet cannot *name* what it was not given: the kernel proper can reach only what its framework build defines, and the framework build can reach the host only through the ABI table, so the question "which globals must we partition?" has no remainder. Every host global is unreachable unless the ABI carries an operation on it, and the ABI is one struct, short and reviewed. And every crossing carries a typed, per-instance object, a handle to a device, a grant of frames, a name for a thread, which is what lets the host charge every resource to an instance and revoke every handle with one store. What separates it from machine virtualization is that a crossing is a function call on the caller's stack, an indirect call through the table, the host sees the caller's context, there is one scheduler, and there is one boot image.

| | Machine | OS | API |
|---|---|---|---|
| Reach decided by | hardware | bookkeeping | names and imports |
| Access checked by | hardware | permissions | handle and owner |
| Crossing | VM exit | syscall | function call |
| Kernel per tenant | one each | shared | *N* instances |
| Kernel globals | duplicated | partitioned | per-kernelet windows |
| Host globals | hidden | shared | unnameable |
| Schedulers | two | one | one |
| Kill and reclaim | destroy VM | tear down views | unmap and release |

*Table 1. Three ways to draw a tenant boundary.*

The boundary is not drawn by the compiler alone, and the paper does not claim it is. Name resolution inside the kernelet build and the import table of the kernelet image decide what a kernelet can *reach*; run-time checks on handles and on frame ownership decide what it may *touch*; per-instance page tables make its data *private* and turn a class of host bugs into faults. Language-based isolation from SPIN [7] through Singularity [8] and RedLeaf [9] built most of these pieces for components inside one system, and rump kernels [10] compiled an unmodified kernel against a facade for portability; [§8](related-work.md) credits both. What is new is the setting and four things it forced. The cut is made at the framework's API, so the tenant's kernel is a complete Linux-compatible kernel. The virtualized API is the framework's own source under a build configuration, and the boundary is one table of C-ABI functions checked against the kernelet image's symbol table, not a rewritten kernel. Per-instance windows in one ring-0 boot image spare the kernel's globals a rewrite. And two kinds of lock, host and kernelet, make killing an adversarial instance sound. The title's "between" holds on this axis, reach and access; [§6](implementation.md) shows that on containment of the host and on side channels the design sits below a microVM.

## Three obligations {#obligations}

*Every instance needs its own state.* The Asterinas kernel proper has 96 statics holding per-tenant state. Rewriting each into a field threaded through every call touches, by a call-graph estimate, some 700 functions and hundreds of types; Asterinas Kernelets uses page tables instead. The kernelet image's writable sections are linked at one fixed address, and each instance's page tables map its own copy of them there, so the statics keep their addresses and no source changes.

*The host must retain no reference into an instance,* or killing it leaves dangling references and reclaiming it hands the next tenant frames the host still points at. The host remembers instances by *names*, integers meaningful only to the instance that minted them.

*Misbehavior must end one instance.* A panic, an unmet allocation, a spin with preemption disabled, or an operator's kill must end the instance without leaving the host inconsistent and without relying on the instance's destructors.
