# Design log

Working log of the Blueprint › Design rewrite. One entry per iteration: what was written, what was decided and why, what is open, what comes next. The register of decisions and assumptions that a reader of the book should see is `src/notes/design-register.md`; this file is the working record behind it.

## Upstream changes needed

Changes the design forces in the Paper or the Overview. Not applied; listed for the owner.

- **Overview › Terminology**, bullets "endovisor ABI" and "crossing", and the definition paragraph's "implements the endovisor ABI through which a kernelet reaches it": the Design chapter uses *endovisor ABI* for the endovisor's user-space interface to the kernelet runtime and *image ABI* (service table and entry table) for the function-pointer tables; a crossing is any call through the service table. The Terminology page should adopt these; the "kernelet build of OSTD" bullet should say "virtualized over the service table".
- **Overview › API virtualization, in one page**, paragraph "The kernelet" and "Three lines, not one": same rename, "endovisor ABI" → "the image ABI's service table"; "the ABI is one struct" → "the service table is one struct".
- **Overview › Why it is hard**, C5: "the kernelet build of OSTD, the endovisor ABI and the device backends" → "…, the image ABI and the device models".
- **Paper › API Virtualization**: the paragraph on the kernelet image uses "endovisor ABI" for the function table; should become "the service table". Table row "Reach decided by: names and imports" stands.
- **Paper › API Virtualization** and **Overview › Builds** claims of "exactly two global symbols": drop; the checkable property is "no undefined symbols and no relocations".
- **Overview › API virtualization, in one page**, "Three lines, not one": should state, as Boundaries and trust now does, that a kernelet's page tables protect the kernelet from the host's stray pointers and nothing from the kernelet, and that the security argument rests on the kernel proper's `forbid(unsafe_code)` and OSTD (kernelet build)'s correctness.
- **Overview › Terminology** and **Paper › API Virtualization**: the Design chapter now names the kernelet build of OSTD **vOSTD** (register D69) and says plain OSTD for the host build; the Terminology bullet "the kernelet build of OSTD" and the Paper's uses of "OSTD (kernelet build)" should adopt the name, and the architecture figure's box label "OSTD (kernelet build)" could read "vOSTD".
- **`AGENTS.md` › Vocabulary**: the rows "the facade" (`kernelet-abi`) and the identifier list (`KerneletEntry`, `KerneletCtl`, `EndovisorServices`, `endovisor()`, `CURRENT_KERNELET`, `#[kernelet_drop]`, crates `aster-kernelet`, `kernelet-abi`, `endovisor`, the `14aster_kernelet` prefix) describe a design the Blueprint no longer has; the Design chapter's names are the kernelet API's control and service halves, the image ABI (`ServiceTable`, `EntryTable`, `BootArgs`), the `kernelet` feature build of `ostd`, and the endovisor as a module of the kernel crate. Not edited, since `AGENTS.md` is the owner's.

- **Paper › Introduction and Evaluation, Overview › API virtualization**: the sentences that count "one copy per block request" and "two copies per packet" describe the first version; the second version (Design › Zero-copy I/O) has zero host copies for block and tier 2 network and one for inter-kernelet transfer, with the fixed-cost argument (no exits, one or no wakeup) that the Evaluation page could carry as an analytic result until a prototype measures it.
- **Executive Summary**: may name I/O as the second edge beside density; not edited.

## Iteration 0: plan

**Read.** The figure; the Overview; the Paper; `AGENTS.md`; the Asterinas tree at `ab9a4cfdc` (HEAD, 2026-08-31): `ostd/src` (222 files, 40,945 lines), every `pub` item by module, the kernel's `use ostd::…` imports expanded to leaves (173 distinct items, 1,182 imports across 424 files), the hook traits (`GlobalFrameAllocator`, `GlobalHeapAllocator`, `Scheduler`, `LocalRunQueue`, `UserModeHooks`), the `Task` struct, the module re-exports.

**Written.** The Design index with the question-to-page map and the page list; fifteen placeholder pages; two Notes placeholders (inventory, register); this log.

**Decided.** The chapter's shape: two framing pages (boundaries and trust; builds and images), the two halves of the kernelet API as two pages, the taxonomy as an index page with the table plus six resource pages, two cross-cutting pages (faults and reclamation; channels), and two pages for question 4 (endovisor; runtime). Reason: each of the four questions gets pages a reader can find from the index, and the resource pages follow OSTD's own module boundaries so the taxonomy table can point into them.

**Open.** All mechanism decisions listed in the prompt. To be taken on the builds-and-images page first, since every later page depends on them.

**Next.** Iteration 1: the OSTD API inventory from the tree into The Notes.

## Iteration 1: the OSTD API inventory

**Written.** `src/notes/ostd-api-inventory.md`: sizes measured on the tree (`ostd/src` 40,945 lines, `ostd/libs` 4,653, `kernel/core/src` 126,228, `kernel/core/comps` 39,341, `kernel/libs` 17,279); the entry, hook and macro surface (fourteen hooks, each with where the kernel binds it); every public item by module with its import count from the expanded `use ostd::…` leaves (173 distinct items, 1,182 imports, 424 files); which 21 files touch machine-level items; the sixteen components with sizes and whether they face the machine.

**Verified against the tree.** `ReturnReason` has three variants; `Error` has exactly seven; `UserContextApi` exposes only the instruction and stack pointers. Two entries were corrected accordingly.

**Process note.** One command changed directory into the Asterinas tree and ran `make check` there by mistake; it failed at once on a missing Python module and `git status` shows the tree unchanged. Every later command is run from the book's directory with absolute paths.

**Next.** Iteration 2: Boundaries and trust, then Builds and images, which takes the three open mechanism decisions.

## Iteration 2: Boundaries and trust; Builds and images

**Written.** `principles.md` (parties, the four interfaces named, crossings, threat model, invariants I1–I8 each with its standing) and `builds-and-images.md` (D1 feature build, D2 tables at entry, D3 fixed addresses in the window at entry 500, the window layout with `KW_TEXT`/`KW_DATA`/`KW_META`/`KW_SHARED`/`KW_HEAP`, the data template, embedding by copy at registration, the kernelet linker script, the seven-item audit). Also drafted `kernelet-api-control.md` and `kernelet-api-service.md` (to be reviewed in iteration 3). Register entries D1–D9 and A1–A4.

**Reviewed.** Two subagent reviews, one per page. Principles: 21 findings; 19 applied (host-kernel composition, "unmodified" → "same source under the feature", confinement claim about OSTD (kernelet build) corrected to "a memory-safety bug is a host compromise", data crosses through shared pages, I1/I2/I3/I5 restated to what the mechanisms deliver, I6 says how interrupt and deferred work is charged, I7 defines depth zero, crossing defined as any service-table call, first uses linked, standings labeled, dangling references removed); 2 rejected as the reviewer's misreading of `AGENTS.md` (spelling is American; there is no facade row). Builds: 27 findings; 25 applied, the decisive one being the code model (the kernel model cannot link at entry 500; now PIC small model, static non-PIE link), plus: empty level-3 table at 500, section order and `.cpu_local` bounds in the entry table, `.eh_frame_hdr` and the unwinder's symbols, `compile_error!` instead of a build script, `e_entry` and a fixed-offset entry table instead of symbol lookup, `KW_META` 8 GiB, `KW_SHARED`, copy at registration billed at ~14 MiB per kind, `-F unsafe_code` and the fourteen-crate allowlist, `--no-default-features`, boot code absent under the feature, a second linker-script template, source hash in the entry table, why Global is impossible, linear-map consequence in D3's cost; 2 were the same spelling misreading and the terminology divergence, which is upstream.

**Decided.** D1–D9 (register). The kernelet image's code model (PIC, small) is a consequence of D3 rather than a decision of its own.

**Open.** Whether the boot image should carry kernelet images as bootloader modules (A: extension). The exact stack reserve (A3).

**Next.** Iteration 3: review and commit the control and service pages; then Virtualizing OSTD (index and memory).

## Iteration 3: the two halves of the kernelet API

**Written.** `kernelet-api-control.md` (images, identity, configuration and its validation, hooks and what they may call, `guest_memory`, the lifecycle with its state machine and concurrency rules, the per-kernelet host state, the two host-wide tables, costs) and `kernelet-api-service.md` (the CPU slot, host-private per-task state, the shared pages including a host-wide clock page, the entry table, the twenty-five-function service table with the prologue and epilogue, every function's checks and cost). Also `virtualizing-ostd/index.md`, the taxonomy (72 rows; to be reviewed in iteration 4).

**Reviewed.** Two subagent reviews. Control half: 28 findings, all applied; the decisive one was that the two halves disagreed on who maps grains into the window (now D10: the kernelet does). Also removed the epoch and handle vocabulary that had leaked from the earlier design, added the `oops` wire, gave the workers an origin (entry index 1, one per virtual CPU, D11), closed the `Created` dead end and made `destroy` retryable by reference, chose Zombie-and-retry for pins, made the grant table append-only and chunked, added an operation count so control operations cannot race destroy, listed hook-safe methods, named the no-process problem for device I/O (A5), added explicit host-bytes accounting, listed `CreateError`, made the generation non-zero so the owner array is 8 bytes per grain, named `alloc_segment_aligned`. Service half: 30 findings, all applied; the decisive one was that the termination counter and kill flags lived on a page the kernelet could write (now host-private, D8 revised); also the prologue's error paths and memory ordering, the boot task through `e_entry`, generation-checked task names, park tokens against lost wakeups, edge-triggered job delivery, `root == 0` shootdowns, unregister-in-use errors, writable-pointer ranges, `-CANCEL`, `task_exit` exempt from the dying check, a stack-reserve breach killing the kernelet, the double-fault gap named (A6), the scheduler's CR3 restore and the `ACTIVATED_VM_SPACE` cache, the user-mode round trip's TLS and FPU state kept in the CPU under the kernelet's preemption count, non-sleeping hooks with device threads (D12), the clock page.

**Decided.** D10, D11, D12; D8 revised. A5, A6 added.

**Open.** Whether device threads can drive host file and socket objects without a process (A5).

**Next.** Iteration 4: review the taxonomy index; write Memory and Tasks.

## Iteration 4: the taxonomy and the first resource pages

**Written.** `virtualizing-ostd/index.md` (72 rows), `memory.md`, `tasks.md`, `interrupts-and-time.md`, `user-mode.md`, `devices.md`, `the-rest.md`. Memory and Tasks reviewed and rewritten; the other four await review.

**Reviewed.** Memory: 23 findings, all applied; the decisive ones were that the kernelet would have had to write the host's level-3 table to hook its own level-2 tables, and that the bootstrap of the first grain was circular. Both are gone: the host bootstraps the heap window at creation and pre-installs level-2 tables in reserved frames of the kernelet's own runs (D10 revised), and the grant table and radix are host-written shared pages the kernelet reads (D29), which also removed `grains_take` and the linear-map exception (D14 withdrawn). Memory is granted in contiguous runs with metadata at the head (D13 revised, D30), which lifts the 1 MiB contiguity ceiling the reviewer found and names the remaining one. Also: activation cache per task, page-table drop at task exit, per-op shootdown with flush-all, DMA paths, `DynCpuLocalChunk` virtualized, the precedence bug in `KW_HEAP`. Tasks: 18 findings, all applied; the decisive one was that RCU grace periods would never complete while a virtual CPU is idle (now an extended quiescent state, D32, A9); also a strong `Arc` held per running task, registration in `run` before unpark, `task_destroy` for never-run tasks, entry indices from 2, the `Waker` keeping its `Arc`, a separate `preempt_switch` entry since `switch_to_task` asserts it may sleep (A8), `CpuLocalCell` ops under the preemption count, `user_run` never switching, affinity and priority builders on `TaskOptions` with three `cfg` lines (D31), edge-triggered idle wake, load-average effects listed.

**Decided.** D10, D13 revised; D14 withdrawn; D23–D32. A7–A9.

**Next.** Iteration 5: reviews of the taxonomy, interrupts and time, user mode, devices and the rest; then faults and reclamation, channels, the endovisor, the runtime.

## Iteration 5: the last pages drafted; reviews in flight

**Written.** `faults-and-reclamation.md` (three tiers, the marking sequence, how a task is stopped in each of its four states, the ten-step destroy, why release is safe), `channels.md` (the vsock switch, the copy path, the frame-move extension), `endovisor.md` (the component, the `Sandbox`, `Endpoint`, `DeviceModel`, the `/dev/kernelet` ABI with typed ioctls, policy), `kernelet-runtime.md` (OCI lifecycle mapping, `config.json` mapping, the ext2 image and `virtiofs`, user-space NAT, the agent, containerd shim). Register D34–D45, A11. No `To be written` remains under Design.

**Applied.** The taxonomy review's 21 findings across six pages: `GsBase` virtualized to MSR accesses (D33), ticks carry the interrupted task and privilege with `Task::current()` overridden during delivery (A10), bottom halves after tick callbacks, `map_iomem` unreachable rather than failing, the exit-code path through a new `exit_with_code`, the panic-handler expansion capturing the message, `IoMem` impls and `mmio_base`, the counting paragraph and the `cfg` inventory corrected (16 component-naming files counted on the tree).

**In flight.** Reviews of interrupts and time, user mode, devices, the rest, faults, channels, the endovisor, the runtime.

**Next.** Apply the eight reviews; final pass over the whole chapter; final report.

## Iteration 6: the eight reviews applied

**Applied.** Interrupts and time (20 findings): the interrupted thread reaches the tick callbacks as an argument through two `cfg` lines (D46, A10 withdrawn); ticks coalesced with a count; busy defined over non-worker tasks; `bottom_half::process_l1` virtualized (it forgets its guard on the tree); lines bound to a virtual CPU (`vcpu` on `DeviceDesc` and `DeviceEntry`); `JOB_CANCEL` removed. User mode (21): the user context must be on the task's kernel stack, because the host's entry stubs use it as a stack (D47); classification, NMI and machine-check handling and the interrupt arm move into `user_run`, with interrupts re-enabled before every return; CR2 read by the host; the four fallible routines with the tree's return conventions; the host's fault handler is exception-table-only for kernelet tasks; `preempt_switch` covers exception returns; I6 qualified; A12. The rest (18): the entry sequence gains command-line parsing, `log::init` and the bootstrap flag; the oops path is off on the tree (`PANIC_ON_OOPS`) and the kernelet build turns it on (D48); the report moves to OSTD's `catch_unwind` with a stashed message, since a proc macro cannot see the feature and the kernel's handler cannot know a catch; `__main_epilogue` and `__handler_entry` in both builds; `logger` stays (D49); workers spawned suspended; `EXIT_RESTART`. Devices (25): the real `cfg` set including the PCI transport; the inbox protocol (D50); completion rules for a chain whose status byte is unowned; reset; the network justification corrected (the host has `AF_VSOCK` but no packet sockets). Channels (25): the host kernel *has* a guest-side `AF_VSOCK` layer, so D39 now rejects a second transport for it; the credit contract with the tree's socket layer and header rewriting (D51); which thread performs each copy; host-endpoint credit and stream semantics; CIDs never reused. Endovisor (29): a module of the kernel crate, since everything it needs is crate-private (D40 revised); `CREATE` configures and `START` creates (D52); real `ioc!` forms, no pointers in `Pod` arguments, `CLOEXEC`, possession as capability (D53); the retry thread. Runtime (25): the sandbox boots at OCI `create` and the agent dials out (D54); per-stream stdio over the agent; hooks, `kill` in `created`, `delete` preconditions per the specification; file bind mounts copied; images cached read-only under an overlay; `virtiofs` client exists on the tree. Faults (18): the reaper task does everything that may sleep and reaches `Exited` (D56); the prologue terminates a dying kernelet's caller instead of returning `-DYING`; the switch away from a kernelet task loads the host root into CR3 (D57); grains zeroed at grant (D55); never-run tasks reaped at the mark; the drain list gains `kernel_pt`, the scheduler group, the tick list, the deadlines and the switch table.

**Decided.** D46–D57; D28, D36, D39, D40, D43, D44 revised; A10 withdrawn; A12 added.

**Tree changes noted (both builds).** `ostd-macros`: `#[ostd::main]` and `#[ostd::panic_handler]` (and the test variants) end in `::ostd::boot::__main_epilogue()` and enter through `::ostd::panic::__handler_entry(info)`. OSTD host build: `after_switching_to` hands a kernelet task's last `Arc` to the reaper; the switch away from a kernelet task loads the host root. Kernel crate: `PANIC_ON_OOPS` initialized under the feature; `TaskOptions::cpu_affinity`/`priority`; the tick callbacks take the interrupted thread.

**Next.** Final pass: a cross-chapter consistency review; render the Design index; final report.


## Iteration 7: final pass

**Reviewed.** One cross-chapter consistency review over all sixteen Design pages, the register and the inventory: 20 findings, all applied. The substantive ones: `exit` and `panic` on the service page still said they call `on_dying` themselves (now `mark_dying` and the reaper); the window table and the principles page listed the grant table under `KW_DATA` and omitted the clock page from the shared pages; two pages still called the endovisor a crate; the taxonomy's waker row contradicted Tasks; the function count was wrong (24); the tick delivery dropped the sampled privilege; the control page's D10 bullet described the pre-revision division of labor; item 7 of the cfg inventory still listed `aster_logger` as host-only. Register rows reordered numerically; D9, D23, D8 reworded; D10 points at Memory.

**Verified.** `make check` → `check: OK`; `make build` exits 0; `make render PAGE=blueprint/design/index.html` painted the figure and the question table (looked at). Working tree clean at commit `9500c42`.

**Exit criterion.** All four questions answered (Q1 control half; Q2 taxonomy of 73 rows plus six resource pages; Q3 service half; Q4 endovisor and runtime); no undeferred "To be written" (the Blueprint index's block defers the implementation, evaluation and limitations chapters with scope); 57 decisions (one withdrawn) and 12 assumptions (one withdrawn) in the register; 10 **[unverified]** marks in the chapter, each an assumption row.

## Iteration 8: the maintainer review

**Reviewed.** One subagent reading as the Asterinas maintainer, all fifteen pages, against feasibility, simplicity, efficiency, soundness and security, with a linker experiment (`scratchpad/poc/link`); twenty ranked findings, thirteen simplifications, a security table. Adopted, with the decision recorded: kernelet tasks are host kernel threads through a `spawn_task` hook, since the tree's class scheduler dispatches on `as_thread()` (D61); the CPU budget is a quota throttle in OSTD plus per-thread `nice`, since the tree has no group scheduler (D62); the link recipe needs `-no-pie`, and the audit checks `ET_EXEC`, no `.dynamic`, program-header flags, and derives the `unsafe` allowlist (D3 revised); the window is indexed by physical address in two top-level entries, mapped by the host, which makes every `mm` item but four identical and removes slots, the radix, run-head metadata and every kernelet-written window page-table entry (D58, superseding D10 and D13; A13); no service call returns through a pointer, `MAX_VCPUS = 64`, the host's fault handler is exception-table-first for kernelet tasks at any address (D65); `max_tasks` and charged stacks (D64); hooks on a per-CPU host stack under `catch_unwind`, a hook panic kills the kernelet (D63); `preempt_switch` is the tree's switch protocol entered from the trap-return path (D16 revised); a busy virtual CPU's ticks are consumed on the interrupted task at tick points, which withdraws D46 and its two `cfg` lines (D66); the mark of death is a compare-and-swap, a store and a signal, the reaper does the rest, `on_dying` does not block (D56 revised); the vsock switch rewrites the source CID; vsock pairs are deny by default (D68); TLB batches collapse to one call (D60); the host's need-preempt decision is forwarded into the record on the `user_run` path; the boot task exits and no idle threads are spawned (D26 revised, D67); each task holds its `Arc<VmSpace>` (D59); bind-mounted files go through the agent into the overlay upper; `console_write` merged into `log_write`, `exit` and `panic` into `stop`, `tick_enable` dropped, the tables' version fields dropped for the hash: 21 service functions; `KW_DATA` as one 2 MiB page; the kernel-half compare at root registration; no `INDIRECT_DESC` or `EVENT_IDX`; the `ctx` check tightened above the entry stack pointer.

**Rejected, with the reason.** Dropping the `.cpu_local` replicas for a heap `Vec`: the kernel proper's own `cpu_local!` statics (run queues, softirq masks, timers) would no longer be identical code; kept, and the guard around `cpu_local_cell!` operations kept, since an atomic read-modify-write on the replica does not close the race in forming the replica's address. Lazy root registration: the per-root active set that `tlb_shootdown` needs wants an explicit table. One device thread per kernelet: serializes a sandbox's block and network I/O for one stack. Direct sender-thread-to-receiver-chain vsock copy: halves the copies but adds a second path when no receive chain is posted; listed with the frame move as an extension. TCP forwarding over vsock instead of a NAT: changes what `eth0` means to the tenant. Linking in the top 2 GiB: recorded as D3's rejected alternative. Smaller kernel stacks: the tree sizes stacks by one build-time constant; `max_tasks` bounds the cost instead. Releasing the embedded image's frames after registration: needs a carve-out of the reserved kernel region; noted as a cost.

**Verified.** `make check` → `check: OK`; `make build` exits 0. A cross-chapter consistency review follows in iteration 9.


## Iteration 9: consistency after the maintainer review

**Reviewed.** One cross-chapter consistency review: 23 findings, all applied, none changing a decision. The four that mattered: the taxonomy still parked the boot task; the control and faults pages still let `on_dying` sleep; the control page's decision summary still had hooks on the kernelet task's stack; the faults page's exempt list still named `exit` and `panic`. The rest were stale names (`task_set_prio`, `HookPanicked`, `EntryTableVersion`, `cpu_weight`), stale attributions (`kill` doing the per-task work, metadata at the head of runs, scheduler groups) and register drift (D9, D10, D12, D15, D19, A10).

**Verified.** `make check` → `check: OK`; `make build` exits 0.

## Iteration 10: Zero-copy I/O, the lending device model

**Written.** `src/blueprint/design/zero-copy-io.md`, the second version of devices: rings read through the checked accessor, entries that lend frames, submission in the notify hook straight into the host driver, headers in the entry, lending enforced by a vOSTD type and a host lend count, a polling bit, block at two tiers (extent-backed hardware DMA; file-backed one copy), network transmit with a host-owned header and receive at two tiers (steered queue zero-copy; shared queue one copy), inter-kernelet one copy frame to frame plus grain moves above 1 MiB. Four Mermaid figures. Register D70–D76, A14–A16. Pointers added to Devices, Channels and the taxonomy.

**Measured here** (scratchpad `zc/bench.c`): memcpy 64 B–2 MiB hot and cold; map, touch, unmap and protect pairs with and without other running threads; a futex round trip. **Published**: Rizzo, Lettieri, Maffione (ANCS 2013) for exit and register-access costs and the 1 Mpps figure; Agache et al. (NSDI 2020) for Firecracker's block and network figures; de Bruijn and Dumazet (netdev 2017) for MSG_ZEROCOPY.

**Decided.** The metric: host CPU per request as fixed plus per-byte terms, because the microbenchmarks show a small copy is 1–3 % of a request's fixed cost and the fixed cost is where exits and wakeups live. The design attacks both terms.

**Open.** The hook's 0.2–0.5 µs is estimated; the host drivers' borrowed-frame constructors do not exist (A14); tier 2 receive needs steering (A16); nothing has run.

**Next.** Review by a maintainer-and-performance-skeptic subagent; revise; up to five iterations.

## Iteration 11: Zero-copy I/O after review 1

**Review 1** (maintainer and performance skeptic; 43 tool uses on the tree). Four tree claims did not hold: the host block layer submits through a sleeping lock and a per-device thread, virtio-blk allocates and spins, NVMe is synchronous; the 16-frame bound misread `max_nr_segments_per_bio`; the stack's socket buffers are heap byte rings and smoltcp copies, so "zero-copy transmit" on the kernelet side was false; `notify_poll_end` is not a poll loop. Security: owner check and lend count were two steps; block headers (sector, lengths) were not in the copied-out-and-validated rule; the polling bit needed `SeqCst` fences; the lend count was absent from destroy's drain list; MOVE's preconditions were incomplete; per-request IOMMU mapping was uncounted. Argument: exit unit cost for user-space monitors too low; tier 1 receive copy is cold; "no polling core" overclaimed; references to the density study dangle on this branch; Rizzo's 1 Mpps was the paper's result, not the baseline. Length 4,500 words against 3,000; terms undefined for the stated reader.

**Revised.** A14 and D73 restated against the tree (`submit_nowait`, asynchronous NVMe; until then block pays one host-thread wakeup per batch); segments as runs within a grain; the transmit claim narrowed to the host side; the poll loops specified as new code on the kernel proper's per-device threads with a threshold of four; entries copied out whole and validated (sector range, alignment, `nseg`, `id`); owner-and-lend word with one compare-and-swap; `SeqCst` fences; lend count in the drain list and I4; IOMMU mapping at grant (D77); MOVE dropped from the page and left as the Channels extension with the measured crossover as its bar; unit costs split by exit kind (A15); a cold 1,500-byte copy measured (231 ns); the polling claim restated as the tenant's own core; density-study references removed; Rizzo's baseline corrected; terms defined on first use; page cut to about 3,300 words with code and tables.

**Next.** Review 2.

## Iteration 12: Zero-copy I/O after review 2

**Review 2** (42 tool uses on the tree; iteration 11's fixes verified). The owner-and-lend word did not fit 64 bits (a `KerneletId` is 48); the long-header transmit path transmitted a tenant frame after checking a copy (TOCTOU); offload fields were missing and ARP and neighbor-discovery unvalidated; posted receive frames made the polling threshold always true; `lend-chan` reintroduced the head-of-line stall D51 rejects and an uncapped copy in a hook; the kernelet-side transmit saving was false (the driver is handed a heap `Vec`) and writeback copies; "one owner check per 2 MiB" assumed contiguous page-cache frames; file extents were unsafe without block pinning; the Rizzo attribution was still wrong; the D76 crossover contradicted the cold numbers; two arithmetic slips; the Zombie bound was unverified and contradicted D36; validation gaps; D77 needed an isolation-floor justification; A14 was incomplete; `LentFrame` duplicated `DmaStream`'s ownership.

**Revised.** Word layout slot 16, generation 32, count 16 with saturation and rollback; every header a device reads is the host's copy, including the long-header path; offload fields in the entry and validated; ARP and neighbor-discovery fields checked, VLAN refused; the threshold counts initiated requests only, receive suppression in the drain-until-empty shape; `lend-chan` makes credit equal posted frames per connection, no host queue, a 16 KiB cap; the kernelet-side transmit claim withdrawn and frame-backed transmit buffers listed as kernel-proper work; segments as contiguous runs, sixteen pages per entry; tier 2 extents restricted to block devices and partitions; Rizzo's sentence and sections corrected; the move bar restated at a whole grain; the hook bounded at 32 entries per call; 12–77 %; D36 wording and request timeouts as unverified A14 items; the validation list completed; D77 justified; `LentFrame` replaced by the tree's `DmaStream` ownership. Register D72–D74, D76 and A14 rewritten; the taxonomy pointer corrected.

**Next.** Review 3.

## Iteration 13: Zero-copy I/O after review 3

**Review 3** (30 tool uses on the tree; iteration 12's fixes verified). Vsock credit is a byte window while the switch consumed one posted frame per `TX`, so a sender within its credit could be refused, and header-only packets (open, close, reset, credit) had no frame to land in; the lend count was not on the Faults page's drain list; "no safe code can free a lent frame" overclaimed refcount-plus-driver-table, and the kernel proper is `deny`, not `forbid`; transmit validation lacked an EtherType restriction, router-advertisement and redirect refusal, and a within-`hdr_len` rule; tier 1 demultiplexing dropped multicast and ignored single-MAC cloud hosts; the polling bit had two clearing rules; the device lock's interrupt discipline was unstated; the lend ceiling is reachable with sixteen devices; the Channels sentence still said 256 KiB and the control page still defined the owner array as `Option<KerneletId>`; the polling ratio needed splitting by baseline; the futex wakeup is an upper bound; block has two wakeups until A14; completion-side host CPU is uncharged (I6); D77's grant-time mapping was not in A14. Length 3,950 prose words.

**Revised.** Channel frames fixed at 16 KiB with one frame of credit per posted frame and a whole frame charged per `TX`; header-only packets through a bounded per-connection header queue; additive sentences on the Faults page (step 1, the completeness list, the Zombie bound) and the control page (the owner-and-lend word); the ownership paragraph restated; `deny`; EtherType, RA and redirect, within-`hdr_len`, multicast and the single-MAC rule; the bit as an OR; interrupts disabled under the device lock; the ceiling stated; Channels sentence at a whole grain; the polling ratio split; the wakeup marked an upper bound; the block row's second wakeup until A14; the I6 gap stated; grant-time IOMMU code added to A14; the grain-move paragraph, the tree-gap paragraph and the unused packet-rate figures cut; terms defined (TLB shootdown, offload, MAC, ARP, edge-triggered). Register D72–D76 and A14 rewritten.

**Next.** Review 4.

## Iteration 14: Zero-copy I/O after review 4

**Review 4** (27 tool uses; iteration 13's fixes verified; every table cell and ratio re-derived). The channel device delivered no header to the receiver (the socket layer needs one on every packet) and no completion carried an assigned connection number; `conn` was never validated, so a third kernelet could post a frame for another pair's connection; two lock orders could deadlock (a channel hook taking another device's lock; a driver completing under its own lock); posted receive frames are not bounded by request timeouts; the entry is 544 bytes and an arbitrary `id` needs a lookup the hook cannot allocate; the grain-unmap figure was inferred from the 4 KiB measurement but labeled measured; the channel window was unstated; tier 1 broadcast was an unbounded host cost; D77 widens the floor's DMA relaxation; the 62-segment bound is virtio-blk's, not the request queue's.

**Revised.** Connections named by the vsock four-tuple in the entry's header, no host-assigned number; the switch writes the validated header at the head of the posted frame; a control pool the receiver posts for header-only packets, with a 64-deep host queue while it is empty; the channel validation rule; the switch's tables under the switch's lock; completion callbacks with no driver lock (A14); a receive-queue reset at `on_dying` (A14); 544 bytes and `id` below the ring size; the unmap figure marked estimated on both pages; four frames of credit per connection, fill-before-charge, credit advanced at re-post; multicast by subscription and a per-segment broadcast cap; D77's widening stated with its alternative; channel hooks capped at 8 entries; the citation corrected; DMA, EtherType, neighbor discovery and router advertisements defined. Register D73, D76, D77 and A14 rewritten.

**Review 5** (30 tool uses; iteration 14's fixes verified; every tree claim re-checked; every number re-derived). Six items: on a cloud host virtio-net writes its own receive header into the first buffer, which would be tenant memory; Firecracker's notify exit is kernel-handled through an event descriptor, so the user-space-monitor row was overpriced (1.1–4.5×, not 1.4–6×); the control pool had no reserve, so a third kernelet's connection requests could drop a live connection's credit update, which the tree never retries; rings pinned at attach would keep destroy's step 1 from ever passing; the channel complete-ring cursor was under an unnamed lock; the entry is 536 bytes. Presentation: host-endpoint connections, the control-pool exception in the validation rule, the `hdr_len` offset, torn-down connections' frames, the sender-side socket change, the interrupts-off window. A cut list of about 875 words.

## Iteration 15: Zero-copy I/O, final pass

**Revised.** A host-owned descriptor for in-band receive headers (D71, A14); the monitor row's notify exit as kernel-handled, marked unverified against Firecracker's source, and the ratios 1.1–4.5× and 3–50×; a reserved control-pool slot per live connection and direction with a per-sender quota on connection requests; rings unpinned at `on_dying`; the cursor under the switch lock and the copy outside it; 536 bytes; host-endpoint connections; the control-pool exception; the payload defined as what follows the headers; torn-down connections' frames completed with an error; the socket-layer change in Costs; the interrupts-off window named as the host's interrupt-latency cost. The cut list applied in part: the six fixes added text, and the page stands at about 4,200 prose words against the 3,000 target; the reviewer's own estimate was that 3,400 is the floor without cutting the validation list or the unit-cost derivation, so about 800 words of tightening remain open.

**Closed.** Five design iterations and a final pass, five reviews. This last pass was not re-reviewed by a subagent; what it changed is listed above and its items are one sentence each.

## Iteration 16: Linux as the host

**Written.** A new chapter, `src/blueprint/linux-mode/`, after Design: index, background
(self-contained Linux, every claim hyperlinked to v6.12 source or docs), one-address-space
(the gate), endovisor, tenant, what-differs, evidence. Plus
`src/notes/linux-mode-experiments.md` with the programs and unedited output.

**The gate, and it passed.** A colleague's observation was that kernelets may not need a
private kernel page table if the image is position-independent. Evaluating it turned up a
stronger form: one *physical* copy of the text, mapped at N different kernel addresses,
each followed by that instance's own data at the same relative offset, so that
program-counter-relative addressing selects the right instance's data with no register,
no table and no lookup. Verified in a VM: four instances, one physical text page, four
correct answers.

**Measured** (details in the Notes page): Syscall User Dispatch 936 ns, a twenty-line
per-task hook 118 ns, against 46 ns for a call Linux services itself, all in one guest
under KVM; seccomp user notification 5,721 ns and ptrace 8,221 ns on the build host,
where the floor is 485 ns. Linux mode needs exactly one exported symbol
(`set_memory_x`), because `vmap()` strips the execute bit, no permission setter is
exported, and `execmem_alloc()` is not exported.

**Design chapter changed in the same branch**, because the scheme is better in Asterinas
mode too. Sentences changed and why:
- `builds-and-images.md`, the whole `## The kernelet image` section: D3 said the image is
  linked at fixed addresses inside two top-level entries of a per-kernelet page table.
  That cannot be done on a host whose kernel half is shared, and the separation it
  appeared to give was never real, since the linear map is shared into every kernelet's
  page table. Replaced by the position-independent scheme.
- `virtualizing-ostd/memory.md`, the opening paragraph, the `paddr_to_vaddr` listing,
  step 2 of "How memory arrives", and the cost paragraph: the physical window is gone;
  `paddr_to_vaddr` uses the host's linear-map base; only the metadata window remains
  per instance.
- `virtualizing-ostd/index.md`, the `paddr_to_vaddr` row: same reason.
- `faults-and-reclamation.md`, destroy step 7: there are no two private level-3 tables to
  free; the image range is unmapped and the metadata window's tables are freed.
- `kernelet-api-control.md`, the host-mapped-regions table and the sentence after it: the
  `KW_PHYS` row is gone, since granted frames need no mapping.
- `principles.md`: a new paragraph saying plainly that kernelets are mutually addressable
  and that isolation between them has no second layer.
- Register: D3 and D58 revised, A2 and A13 withdrawn, D78–D80 and A17–A18 added.

**Not changed**, per the task's guard rail: the Paper and the Overview, which describe
per-kernelet data as "per-kernelet windows". That is still a fair one-phrase description
and neither page depends on the addresses.

**Open.** The two hosts' system-call costs have never been compared, because Asterinas
mode's `user_run` return is not measured anywhere in the book. The zero-copy argument has
not been rechecked against Linux's block layer. The metadata address-space budget is
arithmetic, not measurement.

## Linux mode: review round one

Three reviewers read the new chapter in the roles the task asked for: a senior
Linux kernel developer, a senior systems researcher, and a technical writer.
Between them they found three defects in what had been shipped as verified work,
and each one changed the text rather than only its wording.

**The patch was wrong, and it under-sold the result.** The hook returned `false`
from `do_syscall_64`, which forces the interrupt-return path and skips the checks
that allow the fast one. That, not the hook, was most of the 118 ns first
reported. Falling through to the common exit instead gives a median of 39 ns over
five runs, so the gap against Syscall User Dispatch is about 24×, not 7.9×. A
defective patch had been presented as a measurement.

**`vmap` plus `set_memory_x` yields a writable, executable mapping.** The chapter
had asked Linux to export exactly the wrong symbol. `set_memory_rox` clears both
bits; the guest now prints `W=0 X=1` for the text page. And a complete Linux mode
needs three exports, not one.

**The hook overrode seccomp.** It did not test for the marker that says an earlier
stage already answered the call.

The researcher's finding was structural: the Design chapter's revision was
half-done, with about fifteen stale references to the superseded window scheme and
two invariants left stating properties that no longer held. The writer's was that
a ratio had been formed by dividing one machine's numerator by another machine's
denominator.

What the round changed in the argument, not just in the facts: the patch is a
**security** mechanism. Without it a tenant can store to the selector byte, or jump
to the stub's own `syscall` instruction, and reach Linux directly. So on the
no-patch path the kernelet is not the tenant's boundary, and the container's is.
Leading with the speed number had made a boundary look like an optimization.

Also recorded rather than repaired, because each is larger than an edit: invariant
I7 does not hold on Linux; the tenant's process lifecycle and the virtual
system-call page are not designed; the image must satisfy indirect-branch tracking
and nothing in the design says how; and Linux's 16 KiB kernel stack is a
thirty-two-fold mismatch against assumption A3.

Next: re-run the three reviewers against the revised chapter.

## Linux mode: review rounds two and three

Three reviewers read the chapter a second time. Two of them, independently,
led with the same defect, and it was the chapter's own central claim about
security.

**The private window never existed.** The chapter said Asterinas maps only a
kernelet's own grains, so that a miscomputed physical address faults, and that
Linux gives that up. The Design chapter says the opposite in four places, and
decision D58 rejects the private window outright, for the reason that it
reserves address space in proportion to the machine's physical memory for every
kernelet. Grain addressing is fail-stop on neither host. Correcting it removed a
cost Linux mode did not owe and made the host-replaceability claim stronger,
which is the opposite of what a reviewer usually does for you.

**Four taxonomy rows were missing, and all four cut against the claim.** The
kernel-mode fault path, where Linux's handler cannot find a kernelet's exception
table, so a routine first-touch fault becomes an oops. Any other fault in
kernelet code, which is an oops rather than a contained kill. The per-CPU
replica selector, which is safe only under a preemption count no Linux honors,
and which on the patched path runs on the tenant's unpinned task. And the
segment-base registers, which Linux caches per task.

The Linux kernel developer then found four facts that change what the chapter
concludes, each verified in the tree before it was applied:

- Linux clears Syscall User Dispatch in `copy_process()` and in
  `begin_new_exec()`. On the unpatched path only a tenant's first thread is ever
  intercepted. The no-patch path is not a weaker boundary; for a multi-process
  tenant it is barely a boundary at all.
- The legacy virtual system-call page is emulated inside the page-fault handler
  and calls three system calls directly, below every interception point. Linux
  mode carries an operator requirement to boot with it disabled.
- `set_memory_rox` propagates its write-bit clear to the direct-map alias, so
  the shared text protects itself — and cannot be handed back to Linux until the
  permission is restored, which needs a second export.
- A module cannot create a mapping in another task's address space, and pages
  inserted as raw frame numbers lose the pinning interface and copy-on-write. So
  tenant memory works only on the patched path, and the design's memory story is
  narrower than it read.

What the rounds changed in the argument: the chapter no longer says "Linux can
host kernelets". It says nothing found rules Linux out, names three properties
the boundary owes that Linux weakens, and enumerates what is unfinished rather
than glossing it. The one place Linux mode might simply not work is now stated
sharply: on a host whose own build enforces type-checked indirect branches, the
first call into a kernelet traps, and sharing the text is not why.

Next: whatever survives the third pass of the same three reviewers.

## Linux mode: round four, and the finding that changes the design

The Linux kernel developer found something that no amount of reading Linux's
interfaces would have produced, and it is the strongest result the chapter has.

**Kernelet code cannot touch tenant memory at all.** Since Broadwell and Zen, a
kernel-mode access to a user address faults unless the accessing code sets one
flag in the processor's status register around it. Linux's own copy routines are
the code that does so; that is why they are the only code allowed to touch user
memory. And `do_user_addr_fault()` checks this *first*, before it looks the
address up in the process's areas and before any fixup search, reporting a bad
kernel pointer. A kernelet's code, compiled by the ordinary Rust toolchain,
emits a bare copy. So the first byte the kernel proper reads from its tenant
ends the task, present page or not.

The flag cannot be held open across a kernelet's work: it is not preserved
across a context switch, and a kernelet sleeps and takes locks, so it would leak
the permission into unrelated tasks. Linux confines its own such regions to
straight-line code for exactly that reason.

So D82 is not "a fallible copy becomes a service call so that faults are
recoverable". It is "every access to tenant memory is performed by host code",
it is forced by the hardware rather than chosen, and its cost lands on the path
every system call that passes a buffer takes. Unmeasured, and now the chapter's
largest performance question.

Three of my own errors went with it. Restoring the text's permissions belongs to
retiring a *kind*, not destroying an instance — doing it per instance would
un-protect the shared text for every surviving sibling through the alias they
share. "The no-patch path cannot give a tenant memory at all" was one step too
far: what is ruled out is the parked-servicing-thread shape, because
address-space work must run on the task whose address space it is. And the
machine-wide flush is forced by the direct-map alias, not by the image exceeding
a page threshold.

Two structural changes, both asked for independently. The five assumption breaks
became their own page, because they apply to a kernelet's own kernel threads as
much as to a tenant's task and had grown to outweigh the page they sat on. And
the evidence page gained "What to build first": five gated stages, with the
indirect-branch question first because it decides whether a whole class of host
is eligible at all, and process lifecycle last because it blocks a tenant's
second process rather than its first.

The chapter's conclusion is now: nothing found rules out a patched Linux built
without type-checked indirect branches. An unmodified Linux is ruled out.

## Linux mode: round five, and the experiment that settled it

Two reviewers disagreed about the same claim, so I tested it instead of choosing.

The Linux developer said kernelet code cannot touch tenant memory at all, and that
every access must be performed by host code. The writer objected that the argument
as written would rule the copy out on *Asterinas* too, since it is the same source.
Both were partly right, and the missing step was a fact about our own kernel:
**Asterinas does not enable the processor's supervisor-access check.** Its
control-register setup names five features and not that one, and nothing in the tree
emits the bracketing instructions. Linux enables it wherever the hardware has it.

Experiment 6, four cases in the guest:

| case | result |
|---|---|
| bare kernel-mode read of a tenant address | oops, on a present and writable page |
| the module brackets it itself | works |
| Linux's own copy routine | works |
| the supplier's own kernel alias of the frame | works, with no bracket |
| bracketed read of a *bad* address | oops |

The third and fifth rows decide it. A kernelet supplied every frame in its tenant's
address space out of its own grant, so it already holds an alias of each one that is
not marked as user memory; reading through it needs nothing. And bracketing, which a
kernelet may do since it runs in kernel mode, still cannot deliver the *fallible*
contract, because a bad address finds no fixup.

So D82 is an **addressing rule**, not a crossing: the kernel proper reaches its
tenant's memory through its own alias of the frames it granted, never through the
tenant's virtual address, with a crossing only on a miss. That costs a lookup in an
index A21 already requires, it is what the zero-copy design already does, and it
disposes of futexes, which a copy routine cannot express and an atomic on a kernel
address can.

The result worth keeping is not about Linux. The framework's contract for reading user
memory silently encodes the host's policy on a hardware feature, and neither the API
nor its taxonomy mentions it. Porting is what found it, which is the methodological
argument for this chapter existing. `virtualizing-ostd/user-mode.md` now states the
precondition.

Also this round: the unpatched tier is withdrawn everywhere, not just in the
conclusion — Linux clears dispatch at every fork and exec, so it cannot run a process
tree; the fault-containment item explains why no patch is proposed for it, rather than
adding a second ask the chapter could not defend; the stack switch became a decision
with an assumption about it; and the build order's first stage now aims at the
configuration that ships rather than at one no distribution builds.
