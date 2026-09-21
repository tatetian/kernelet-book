# Alternatives considered

*The designs that lost, one paragraph each, with the reason. The reason is what stops the next reader from trying them again. Numbers marked* measured *come from the experiments listed on the [prototype page](prototype.md#earlier).*

## For reaching the kernelet from a system call

**No patch: Syscall User Dispatch.** Linux can turn a task's system calls into a signal, which a stub in the process could forward to the endovisor. *Measured*: at least 885 ns added per call, against nothing measurable for the gate. More important, Linux clears the setting at every `fork` and `exec`, so only a sandbox's first thread would ever be intercepted; the tenant can also jump into the stub's exempt range, or flip the selector byte, and call Linux directly. Linux's own documentation says it is not a security mechanism. Rejected: without a patch the kernelet is not the tenant's boundary.

**No patch: seccomp user notification, or ptrace.** Both put the answer in another process, so each call costs two context switches. *Measured on the development machine*: 5.7 µs and 8.2 µs per call, against 1.9 µs for dispatch on the same machine. Rejected on cost.

**A hook in the architecture's entry code.** The first patch hooked x86-64's `syscall` path. A kernel built with 32-bit compatibility has three more entry instructions, each a complete escape. Replaced by the gate in the generic entry layer, which every entry passes through.

**Servicing calls on a separate kernel thread.** Park the tenant's task and hand the call to a kernel thread per virtual CPU, which can be stopped cooperatively. *Estimated* at 1.5 to 3 µs per call for the handoff, and the servicing thread that loops is no more killable than the tenant's task was. Rejected.

## For tenant memory

**Linux owns the address space; the kernelet keeps a side table.** The first design let Linux's address space be the truth and had vOSTD record, for each frame it supplied, the tenant address it was mapped at, so that copies could go through the frame's kernel alias. Linux tears mappings down without telling the supplier, so an entry could outlive its mapping and then *resolve*, silently, to a frame that might by then belong to another tenant. Keeping it coherent needs Linux's MMU-notifier protocol, a kernel build option, and a non-sleeping lock on every copy. Replaced by [the model](virtualizing-ostd/memory.md#cache), which has no second structure to go stale.

**Bracketing accesses with the processor's user-access flag.** A kernelet runs in kernel mode and can set the flag itself. *Measured*: that works for a good address, and takes the task down for a bad one, because Linux will not find a recovery entry for an instruction in a kernelet. The kernel proper validates pointers by faulting on them, so this cannot deliver its contract.

**The supervisor alias.** Map the model's upper-level entries a second time in the kernel half of the carrier's address space, with the user bit cleared, so that a tenant address plus a constant is a kernel address and a copy needs no software walk. It was adopted on paper with one gate: its cost in TLB entries had to be measured. *Measured in a model*: for a 16-byte copy it saves about 7 ns over the walk when the working set is small and nothing when it is large, where its extra TLB misses cost as much as the walk does ([the table](virtualizing-ostd/memory.md#copies)). Against a saving that small stand real costs: it writes page-table entries Linux believes it owns, in a slot of the address-space layout that nothing reserves; it must be reinstalled in every new address space; and it opens a kernel-mode window onto user pages, which is what SMAP exists to prevent. Rejected.

**Ordinary pages instead of raw frame numbers.** Inserting tenant pages as normal, reference-counted pages would let Linux subsystems pin them, and a pin is a reference that can outlive the kernelet's own idea of who owns the frame, up to and past the day the grant is returned. No tenant operation needs pinning, since a tenant never calls Linux. Raw frame numbers give the right contract: Linux maps what it is told and keeps no claim of its own.

## For tasks

**Letting Linux service the tenant's own `clone`.** Decline the call at the gate, let Linux create the child, and have the kernelet do its bookkeeping on both sides. It is the cheapest way to get a thread that shares its parent's Linux address space. It was dropped because the kernel proper would have to know that its `clone` is being serviced elsewhere, and the design's central claim is that the kernel proper's source does not change. What the kernel proper actually does is create an OSTD task, and vOSTD has to honor that.

**Kernel threads as carriers.** They cannot enter user mode, and OSTD does not say at creation which tasks will.

**Linux's user-mode-helper interface.** It creates a task that can enter user mode with no new export. But every such task starts as a child of a kernel worker, in the root control group, with root's credentials and no seccomp filter, and each of those would have to be repaired by hand on a path where a mistake is an escape. Cloning the root carrier inherits all of them.

**Self-hosted threads.** Make a tenant thread a register file owned by the kernelet, and let a small pool of Linux tasks, one per virtual CPU, each carry whichever tenant thread the kernelet's *own* scheduler picks. This makes the two hosts converge and revives the kernel proper's scheduler. *Measured*: a switch between tenant threads on one Linux task costs 291 ns more than a serviced call, 91 ns of it floating-point state, and the exported helper for swapping that state exists only in kernels built with virtualization support. It is the most promising direction for later work and too large a change to be the first design.

## For containment

**Revoking a kernelet's text.** To stop a carrier that will not leave kernelet code, unmap that kernelet's text and flush every processor's TLB, so that the carrier faults at its next instruction and the die notifier catches it. The range flush is not exported, so this costs a machine-wide full flush per termination, and it turns every forced termination into a printed oops. Replaced by [eviction](faults-and-reclamation.md#eviction), which needs neither.

**Catching tenant exceptions with a signal handler inside the tenant.** Costs no patch lines. Linux then writes a signal frame onto the tenant's stack, which the tenant controls and may have made unwritable, and a trusted trampoline has to live in the tenant's address space. Replaced by the gate's resume hook.

## For the whole mode

**Each instance as a Linux module.** No loader to write and no exports to ask for. Linux's module area is about 1 GiB and every instance would need its own copy of the text: tens of sandboxes per machine.

**Each kernelet in a hardware-virtualized guest, in kernel mode of that guest.** This restores everything: hardware separation, forced termination, exact accounting. It also needs a hypervisor, gives up running in the host's kernel mode, and adds a second level of address translation to every tenant memory access, *measured* at a factor of 1.20 on a realistic working set. That is a virtual machine, and the book is about the alternative to one.
