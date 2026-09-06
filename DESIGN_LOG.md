# Design log

Working log of the Blueprint › Design rewrite. One entry per iteration: what was written, what was decided and why, what is open, what comes next. The register of decisions and assumptions that a reader of the book should see is `src/notes/design-register.md`; this file is the working record behind it.

## Upstream changes needed

Changes the design forces in the Paper or the Overview. Not applied; listed for the owner.

- **Overview › Terminology**, bullets "endovisor ABI" and "crossing", and the definition paragraph's "implements the endovisor ABI through which a kernelet reaches it": the Design chapter uses *endovisor ABI* for the endovisor's user-space interface to the kernelet runtime and *image ABI* (service table and entry table) for the function-pointer tables; a crossing is any call through the service table. The Terminology page should adopt these; the "kernelet build of OSTD" bullet should say "virtualized over the service table".
- **Overview › API virtualization, in one page**, paragraph "The kernelet" and "Three lines, not one": same rename, "endovisor ABI" → "the image ABI's service table"; "the ABI is one struct" → "the service table is one struct".
- **Overview › Why it is hard**, C5: "the kernelet build of OSTD, the endovisor ABI and the device backends" → "…, the image ABI and the device models".
- **Paper › API Virtualization**: the paragraph on the kernelet image uses "endovisor ABI" for the function table; should become "the service table". Table row "Reach decided by: names and imports" stands.
- **Paper › API Virtualization** and **Overview › Builds** claims of "exactly two global symbols": drop; the checkable property is "no undefined symbols and no relocations".

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
