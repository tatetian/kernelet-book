# Tenant memory: deleting the map instead of keeping it

*Three designs against the chapter's newest and most expensive decision. D82 says the kernel proper must reach its tenant's memory through an alias of the frames it granted, and leaves behind an address-to-frame map with two open halves: misses that are structural, and stale entries that resolve silently. The first design here deletes the map. The second makes the translation a single addition. The third asks whether the tenant should be paying for any of this.*

## The observation the cluster turns on

The map D82 asks for already exists, and so does the code that uses it.

The kernel proper builds a page table for every address space it owns, through the framework's cursors, out of frames from its own grant. And it already contains a routine that reaches *another* process's memory without dereferencing a user address: it walks that space's tables, takes the frame, and copies through the frame's own kernel alias. It exists so that one thread can read another's memory, and its documentation notes that the space need not be the active one.

So the mechanism D82 specifies is written, in our tree, above the interface. What is more, every user access in the kernel proper bottoms out in two framework functions, `VmSpace::reader` and `VmSpace::writer`, which the [taxonomy](../design/virtualizing-ostd/index.md) already classifies as virtualized. A second body for those two changes how every tenant access works, with the kernel proper's source untouched and no new framework interface at all.

## The model page table {#model}

*Attacks:* D82's map, its misses, its stale hits, and the sleeping protocol it needs. *Helps:* Linux only, but it removes an asymmetry between the hosts.

Keep the kernelet's page table in Linux mode and never activate it.

The kernel proper's address-space code, its cursors, its mapping and unmapping, and its fault handler are all unchanged. One line inside the framework changes: activation keeps its bookkeeping and drops the register write. The hardware walks Linux's tables; the kernelet's tables become a **model** that the hardware never consults.

Reading and writing take a second body along the shape of the alien-access routine already in the tree. The reader still carries a tenant virtual address; when it copies, it takes the model's cursor over the remaining range and, for each mapped page, copies through the frame's kernel alias. One cursor walk per copy call, not per page and not per byte. An atomic compare-and-exchange takes the same route and becomes an ordinary atomic on a kernel address, which is what a futex needs and what a copy routine could never express.

Faults run the other way. Linux faults on a tenant address and calls the kernelet's handler; the handler queries the model, and on a miss runs the kernel proper's own fault handler, which maps the frame into the model; then it hands Linux the frame so that Linux's tables become a **cache** of the model.

That reversal is the point. `munmap`, `mprotect` and exit are calls the kernelet services itself, so the model is authoritative and Linux's tables are invalidated by the same code that changed it. The stale-hit hazard does not arise, because there is no second structure to go stale. The structural miss does not arise either: an address the kernelet never supplied is simply not in the model, and the model's own miss path is the kernel proper's fault handler.

**What it costs.** A page-table walk per copy call where the design has an instruction, on the path every system call with a buffer takes. And one real risk: the framework's cursor takes an exclusive lock on a subtree, so two tenant threads copying to nearby buffers serialize where before they did not. That is measurable on the existing prototype and has not been measured.

**What it asks Linux for.** Nothing new.

**Verdict.** Promising, and the one to build first in this cluster. It is the only design in the cluster that asks Linux for nothing, it closes both of D82's open halves rather than deferring them, and most of its code is already written.

## The spliced model {#splice}

*Attacks:* the walk the model still pays. *Helps:* **both hosts**, and this is the one that changes Asterinas.

Everything above, plus a splice that makes the translation arithmetic.

The model is a real page table. Take its top-level entry for a slice of tenant address space and install a copy of that entry in the **kernel half** of the tenant's own address space, with two bits changed: the user bit cleared and the no-execute bit set. The hardware's rule, which Linux writes out in its own page-table dumper, is that the effective user and write bits are the **AND** across paging levels and the effective no-execute bit is the **OR**. So every page under that entry becomes supervisor-only and non-executable, while the identical lower tables, reached through the tenant's own top-level entry, stay exactly as they were. One store per slice. No tables are copied and there is nothing to keep coherent, because both paths reach the same leaves.

The translation is then `tenant address + alias base`. On five-level paging one top-level entry covers the whole tenant address space, so it is a single addition the compiler folds into the addressing mode. On four-level paging one entry covers 512 GiB and a tenant's space needs far more, so the form is a sparse slot table: reserve a handful of kernel indices, map each *used* top-level slot into one, and translate with a byte load, a shift and an or. A process in this kernel occupies two or three such slots in practice.

The budget is better than it looks, because kernel-half top-level entries are per address space — which Linux demonstrates in-tree, with a per-process structure it maps in the kernel half at a fixed index. So the same index serves every kernelet on the machine, each address space's copy pointing at its own model, and the address-space cost is a fixed handful of slots for the whole machine rather than a window per tenant.

**What it costs.** A second translation-buffer entry per touched page, since the same physical page is now reached through two virtual addresses. A kernel-range invalidation whose exported form is awkward. And a hardening trade that should be stated plainly: a supervisor-readable window onto a tenant's pages is precisely the confused deputy that the hardware check exists to prevent. The check is not defeated by accident here, it is defeated deliberately and in one place, which is the best that can be said for it.

**What it means for Asterinas.** Asterinas does not enable the supervisor-access check at all, which is why the kernel proper's copies work there and fault on Linux. This splice is what would let it: enable the check, and reach tenant memory through the alias for one add. That is a hardening the host we wrote cannot afford today and could afford under this design.

**Verdict.** Promising, needs work. The mechanism is real and its evidence is in Linux's own source, and it is the only design in the cluster that improves the host we wrote.

## Grant-backed pages {#folios}

*Attacks:* assumption A21, the list of things a tenant loses. *Helps:* Linux only.

The other two leave the tenant's pages inserted as raw frame numbers, which is what costs the tenant direct file input and output, registered buffers for asynchronous I/O, remote direct memory access and a debugger's reads. Insert them as ordinary pages instead, with the kernelet holding its own reference, and the tenant gets all of that back.

It also connects to work elsewhere in the book: a kernelet that holds a real reference to a page can hand it to the host's block layer instead of copying it, which is what [zero-copy I/O](../design/zero-copy-io.md) wants.

**What it costs, and this is the cluster's sharpest conflict.** The pinning refusal and the only exported way to drop a sub-range of a tenant's translations are bought with the *same* flag. Raw frame numbers give the kernelet its invalidation and cost the tenant its pinning; ordinary pages give the tenant its pinning and leave the kernelet with no exported way to invalidate what it has handed out. The two cannot both be had, and no amount of servicing `munmap` in the kernelet dissolves it, because the kernelet's own unmap still has to drop Linux's cached translations.

**Verdict.** Needs work, and the least certain of the three. The benefit is real and the conflict is real, and which way it should go depends on whether a tenant that cannot use direct I/O is a tenant anyone wants.
