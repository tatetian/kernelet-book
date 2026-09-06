# Design log

Working log of the Blueprint › Design rewrite. One entry per iteration: what was written, what was decided and why, what is open, what comes next. The register of decisions and assumptions that a reader of the book should see is `src/notes/design-register.md`; this file is the working record behind it.

## Upstream changes needed

Changes the design forces in the Paper or the Overview. Not applied; listed for the owner.

- (none yet)

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
