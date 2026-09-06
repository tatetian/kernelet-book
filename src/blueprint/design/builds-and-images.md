# Builds and images

This page fixes how the two builds of OSTD are produced, how the kernel proper becomes a kernelet image, where that image's bytes live in memory, how it is entered, and what the build checks. It takes the three mechanism decisions that the Overview's fixed decisions do not settle; each is stated with the alternative it rejects and recorded in the [design register](../../notes/design-register.md). Two terms are defined here and used throughout: a **kind** is a registered kernelet image, and a **grain** is the 2 MiB unit in which memory is granted to a kernelet.

## Two builds from one source {#two-builds}

**Decision D1.** The kernelet build of OSTD is the `ostd` crate compiled with a Cargo feature named `kernelet`. The host build is the same crate without it. The kernelet image and the host image are separate Cargo builds, so feature unification, which would merge the two feature sets inside one build, never applies. Because Cargo features are additive, the kernelet build is always invoked as `--no-default-features --features kernelet`, which is how `cvm_guest` stays off.

```toml
# ostd/Cargo.toml
[features]
default = ["cvm_guest"]
cvm_guest = ["dep:tdx-guest"]
# The kernelet build: the API a kernelet's kernel is compiled against.
kernelet = []
```

```rust
// ostd/src/lib.rs
#[cfg(all(feature = "kernelet", feature = "cvm_guest"))]
compile_error!("`kernelet` and `cvm_guest` are mutually exclusive");
```

Inside OSTD the feature selects implementations, not modules. An item that is *identical* in the taxonomy has no `cfg` at all. A *virtualized* item keeps its public signature and gets a second body under `#[cfg(feature = "kernelet")]`, usually in a sibling file (`task/kernelet.rs` beside `task/mod.rs`) so that the two bodies sit next to each other in review. An *absent* item is `#[cfg(not(feature = "kernelet"))]` on its definition, so that a kernel that uses it fails to compile in the kernelet build with an unresolved name rather than at run time. Which of the three an item is can therefore be read from the source, and a change to OSTD that forgets the kernelet side fails the kernelet build in continuous integration. Whole modules are absent too: `arch::x86::boot`, which carries the multiboot headers and the `bsp_boot` and `ap_boot` assembly with their physical-address segments, is `cfg(not(feature = "kernelet"))`, since a kernelet is entered by the host, not by a bootloader.

The kernel proper is built the same way. The kernel crates gain a `kernelet` feature that turns off the components that face the machine and turns on `forbid(unsafe_code)`:

```toml
# kernel/Cargo.toml (excerpt)
[features]
default = ["cvm_guest"]
kernelet = ["aster-core/kernelet", "ostd/kernelet"]

# kernel/core/Cargo.toml (excerpt): components present only in the host kernel
[dependencies]
aster-pci = { path = "comps/pci", optional = true }
# ... nvme, uart, i8042, framebuffer, and the machine-facing half of time

[features]
kernelet = ["ostd/kernelet"]
host = ["dep:aster-pci", "dep:aster-nvme", "dep:aster-uart", "dep:aster-i8042", "dep:aster-framebuffer"]
default = ["host"]
```

```rust
// kernel/core/src/lib.rs
#![no_std]
#![deny(unsafe_code)]
#![cfg_attr(feature = "kernelet", forbid(unsafe_code))]
```

The `virtio` component stays in both builds; its PCI transport is behind the `host` feature and its MMIO transport is what a kernelet uses ([Devices](virtualizing-ostd/devices.md)). The [OSTD API inventory](../../notes/ostd-api-inventory.md) lists which components face the machine; those six (`pci`, `nvme`, `uart`, `i8042`, `framebuffer`, and the TSC and CMOS parts of `time`) are host-only, and the kernel proper's own files that touch machine items, seven files under `kernel/core/src`, get a `cfg` on the offending lines rather than on the file.

*Rejected alternative.* A second package over the same source, `ostd-kernelet` with `[lib] path = "../ostd/src/lib.rs"` and a build script setting `--cfg kernelet`. It would let one Cargo build contain both variants, which was the reason to consider it, but nothing needs that once the two images are separate builds; it doubles the manifests to maintain and makes `cargo` treat the two as unrelated crates for versioning and publishing. The feature is the simpler mechanism and the two-build structure removes its only drawback.

*Cost.* Two full builds of OSTD and of the kernel proper per boot image, roughly doubling build time (*estimated*); two copies of the compiled text in the boot image, the kernelet's shared among its kernelets.

## The kernelet image {#window}

The kernel proper and OSTD (kernelet build) link into one ELF, the **kernelet image**. The host kernel is a separate ELF, the **host image**. One OSDK invocation builds the kernelet image first and the host image second, embedding the kernelet image's bytes into the host image; the result is one **boot image**, and nothing else is loaded at run time.

**Decision D3.** The kernelet image is linked at fixed virtual addresses, not position-independent, and every kind is linked at the *same* addresses. All of a kernelet's memory, its text, its writable state, its shared pages and its heap with the frame metadata inside it, lies inside one top-level page-table entry of the kernel half, the **kernelet window**: on x86-64, entry 500, the 512 GiB range at `0xffff_fa00_0000_0000`. OSTD's kernel page table allocates a level-3 table for every top-level entry from 256 to 511 at boot and leaves entries 450 to 510 empty beneath it (measured on the tree: `ostd/src/mm/page_table/mod.rs`, `new_kernel_page_table`, and the address constants in `ostd/src/mm/kspace/mod.rs`), so the host and every host user page table hold an *empty* level-3 table at entry 500, which a kernelet's kernel page table replaces with its own. The window is laid out as follows; the constants are the kernelet image's linker script and are exported by OSTD (kernelet build) as `ostd::kernelet_window::*`.

| region | offset in the window | size | contents | mapping |
|---|---|---|---|---|
| `KW_TEXT` | 0 | 1 GiB | `.kernelet_entry_table` at offset 4 KiB, then `.text`, `.ex_table`, `.rodata`, `.eh_frame_hdr`, `.eh_frame`, `.gcc_except_table`, `.init_array`, `.ktest_array`; the kernelet image's read-only segments | the kind's shared frames, mapped read-only, executable where the segment is; identical in every kernelet of the kind |
| `KW_DATA` | 1 GiB | 1 GiB | the writable segment in the tree's order, `.data`, `.cpu_local`, `.bss`; then, from the next page boundary, `.cpu_local` replicated once per virtual CPU; then OSTD (kernelet build)'s own tables (the grant table with its physical-address radix, the task and body tables, the service table pointer) | private frames per kernelet, copied from the image's data template at creation, read-write, non-executable |
| `KW_SHARED` | 2 GiB | 1 GiB | the shared pages: the boot arguments and the info page, which the host writes and the kernelet reads, and the task records, which both write | host frames, mapped read-only or read-write as the page requires; the host writes them through its linear map |
| `KW_HEAP` | 4 GiB | 508 GiB | the heap window: every grain the kernelet is granted is mapped here at `KW_HEAP + slot × 2 MiB`, where `slot` is the grain's index in the kernelet's grant table; each grain's first eight frames hold that grain's frame metadata ([Memory](virtualizing-ostd/memory.md)) | the granted frames themselves, read-write, non-executable |

The writable segment keeps the order OSTD's own linker script uses, `.data`, `.cpu_local`, `.bss` (the `.cpu_local_tss` section between the first two on the tree is absent in the kernelet build, since the TSS is the host's), so that no `NOBITS` section precedes a `PROGBITS` one and `.bss` stays zero-fill rather than file-backed zeros. The per-virtual-CPU replicas follow the segment's end rounded up to a page; OSTD (kernelet build) finds `.cpu_local`'s bounds through the entry table, not through the GS base, which is the host's ([Tasks](virtualizing-ostd/tasks.md)).

Kernel stacks are not in the window. A kernelet's tasks are host-owned tasks ([Tasks](virtualizing-ostd/tasks.md)), and their stacks live where every task's stack lives, in the host's vmalloc area, mapped in every page table; host code that runs on a kernelet's behalf runs on the same stack. The rest of the kernel half, the linear map, the vmalloc area, the host's frame metadata and the host image, is shared into a kernelet's page tables exactly as OSTD shares it into every user page table today, by copying the top-level entries. A kernelet's **kernel page table** is the host's with entry 500 pointing at the kernelet's own level-3 table; every user page table the kernelet creates copies its kernel half from there ([Memory](virtualizing-ostd/memory.md)). No page table but a kernelet's own has anything under entry 500, which is what makes invariant I3 hold for the window: no host task that is not running a kernelet's task can address it.

*Why one window.* Text, data, metadata and heap in one entry means the kernelet's page tables differ from the host's in exactly one top-level entry, so creating a kernelet's kernel page table is one level-3 table plus what it maps, and the audit that the two agree everywhere else is one comparison. Text inside the window rather than in the host's image area means kernelet code is never mapped in the host's page table, so the host cannot call into it by accident, and two kinds can share one address layout because no page table ever holds two kinds.

*Code model.* The window is far below the top 2 GiB of the address space, and OSTD's target, `x86_64-unknown-none`, uses the *kernel* code model with a static relocation model, which assumes every symbol sits in that top 2 GiB and emits sign-extended 32-bit absolute operands; an image linked at entry 500 would fail to link with `R_X86_64_32S out of range` (checked on the tree: `osdk/src/commands/build/mod.rs` passes `-C relocation-model=static`). The kernelet build therefore uses `-C relocation-model=pic -C code-model=small` with every symbol at hidden visibility, and links as a static, non-position-independent executable at the window's addresses. Code is RIP-relative, `KW_TEXT` and `KW_DATA` lie within 2 GiB of each other as the small model requires, the linker resolves every GOT-relative reference at link time, and the output carries no relocations. The regions beyond `KW_DATA` are reached only through computed pointers, never through symbols. *Cost:* RIP-relative code is the default on every other x86-64 target and costs nothing measurable against the kernel model; the rejected large model would cost a 64-bit immediate on every address formation.

*Rejected alternative.* A position-independent kernelet image relocated at load. It would allow several kinds in one page table and let the loader choose addresses, but it needs a relocation processor in the trusted base (`R_X86_64_RELATIVE` entries over the whole image), and nothing wants two kinds in one page table: a kernelet is of one kind. Fixed addresses make `readelf -r` empty, which the audit below checks.

*Cost.* The window's mappings cannot be Global: the same window address maps different frames in different kernelets, so a Global entry would be wrong, not merely stale. A CR3 write therefore drops the window's translations along with the user half's, and a kernelet task resumed after a switch refills its text and data translations from the page tables. **[unverified]**: the size of that refill against a Global-mapped text; the design does not assume PCIDs, and the Evaluation chapter will measure it. And sharing the linear map into a kernelet's page tables means OSTD (kernelet build) can address every physical frame: invariant I2's write confinement rests on that code's discipline, and the page tables back only the host-to-kernelet direction of privacy, as [Boundaries and trust](principles.md) states.

## The data template and per-kernelet state

At creation the control half copies the image's `.data` bytes and zeroes `.bss` into fresh frames mapped at `KW_DATA`, in the segment's own order. The template is the image's writable segment, read from the embedded ELF; nothing depends on section globs or on link-time optimization preserving per-static sections. The `.cpu_local` section is replicated once per virtual CPU from the next page boundary after the segment, and OSTD (kernelet build) addresses a replica by virtual-CPU index ([Tasks](virtualizing-ostd/tasks.md)).

The measured sizes on the tree's own debug image (`target/x86_64-unknown-none/debug/asterinas-osdk-bin`, built 2026-08-28) are `.data` 27,464 bytes, `.bss` 23,944 bytes and `.cpu_local` 1,977 bytes. That is the whole host kernel; the kernelet image's writable segment will differ, larger by OSTD (kernelet build)'s tables and smaller by the host-only components. *Estimated*: under 128 KiB of private writable state per kernelet before the per-CPU replicas, plus 2 KiB per virtual CPU. The heap and the frame metadata are granted memory, charged to the kernelet, and are not part of this floor.

## Embedding and registration

The kernelet image is embedded into the host image by the endovisor crate:

```rust
// endovisor/src/images.rs
static LINUX_KERNELET: &[u8] = include_bytes!(env!("KERNELET_IMAGE_LINUX"));
```

OSDK sets `KERNELET_IMAGE_LINUX` to the path of the kernelet image it built in the previous step. At boot the endovisor registers each embedded image with the control half, which parses the ELF's program headers and *copies* each `PT_LOAD` segment into fresh frames: the read-only segments become the kind's shared frames, the writable segment becomes the data template. Copying, rather than mapping the embedded bytes in place, is what lets `include_bytes!` be an ordinary byte string with no alignment requirement, and it costs one copy per kind at boot, about 14 MiB for the tree's debug image (`.text` 13.8 MB plus `.rodata` and `.eh_frame`; measured with `size -A`) and less for a release build. The parser needs only the `PT_LOAD` headers, the ELF entry address `e_entry`, and the entry table, which lies at a fixed offset (below); it reads no symbol table.

*Rejected alternative.* Passing kernelet images as bootloader modules, which OSTD already supports as `MemoryRegionType::Module`. It would allow a kind to be replaced without relinking the host image, and it is the natural extension when that is wanted. It is not the default because it makes the boot image two files, and because the build's attestation that the kernel proper contains no `unsafe` outside the allowlist is only as good as the build that produced *both* files together.

## The entry point and the two tables {#entry}

**Decision D2.** Control and data cross the ELF boundary only through two tables of `extern "C"` function pointers and the shared pages. The kernelet image's linker script names `_kernelet_entry` as the ELF entry point (`ENTRY(_kernelet_entry)`, so `e_entry` locates it) and places the entry table in its own output section at `KW_TEXT + 4 KiB`, so the host finds both without a symbol table.

```rust
// OSTD (kernelet build), ostd/src/kernelet_side/entry.rs

/// The one function the host calls to start a kernelet.
/// Runs on the kernelet's boot task, on the kernelet's kernel page table,
/// with `KW_DATA` already populated from the template. Never returns.
#[unsafe(no_mangle)]
pub extern "C" fn _kernelet_entry(
    services: &'static ServiceTable,
    boot: &'static BootArgs,
) -> ! { /* store `services`; init OSTD (kernelet build); call `__ostd_main` */ }

/// The kernelet image's entry points and the facts about the image the host
/// needs. Read by the host from `KW_TEXT + 4 KiB` at registration; never written.
#[unsafe(no_mangle)]
#[unsafe(link_section = ".kernelet_entry_table")]
pub static KERNELET_ENTRY_TABLE: EntryTable = EntryTable { /* … */ };
```

The **service table** is a `#[repr(C)]` struct whose first two fields are its size in bytes and a version, followed by function pointers; it is built by OSTD (host build) once at boot and the same table is handed to every kernelet. The **entry table** is the mirror image: size, version, the function through which the host enters kernelet code (the body of a spawned task, by index), the bounds of the image's exception table for kernel-mode page faults, the bounds of its `.cpu_local` section, and the hash of the OSTD source and toolchain the image was built from. Both tables are specified in full on [The kernelet API: service half](kernelet-api-service.md). The first act of `_kernelet_entry` is to check that `services.size` and `services.version` are what it was compiled against, and to stop if not.

Everything else a kernelet needs at boot, its identifier, its virtual-CPU count, its initial grant, its command line and the layout of its shared pages, is in `BootArgs`, a `#[repr(C)]` struct in a host frame mapped read-only at the start of `KW_SHARED`, described with the service half.

*Rejected alternative.* Resolving host symbols by relocation when the image is combined, as a Linux kernel module does against exported symbols. It gives direct calls instead of indirect ones, but it needs either a final link that merges two symbol namespaces, with every `core` and `alloc` symbol defined twice, or a relocation processor in OSTD at boot; and it spreads the import surface over the symbol table instead of one struct with a version. The indirect call costs an estimated one to two cycles when predicted; a whole crossing was measured on the booted prototype at 35 cycles against 34 for a plain call, and the design accepts that order of cost.

## The linker script

OSDK emits a second template for the kernelet build, `x86_64-kernelet.ld.template`, beside the host's. It has three `PT_LOAD` program headers, `text` (R E), `rodata` (R) and `data` (RW), no header or boot segments and no physical load addresses; it places `.kernelet_entry_table` at `KW_TEXT + 0x1000`, then the read-only sections in the tree's order, and the writable sections at `KW_DATA` in the tree's order; and it provides the symbols OSTD's unwinder needs to find frame-description entries, `__executable_start`, `__etext` and `__GNU_EH_FRAME_HDR` (the tree selects the `fde-gnu-eh-frame-hdr` mode of the `unwinding` crate, so without them `catch_unwind` in a kernelet finds nothing), plus `__ex_table`, `__ex_table_end`, `__cpu_local_start`, `__cpu_local_end`, `__sinit_array` and `__einit_array` as the host's script does.

## The audit {#audit}

After every build, before the host image is linked, OSDK checks the kernelet image and fails the build on any of these:

1. The link ran without `--unresolved-symbols` or `-z undefs`, and `readelf --syms` shows no `UND` entry and no `.dynsym` section: the image imports nothing.
2. `readelf -r` shows no relocation of any kind.
3. Every `PT_LOAD` segment lies inside `KW_TEXT` or `KW_DATA`; the writable one inside `KW_DATA` only; no segment is both writable and executable; `e_entry` lies inside `KW_TEXT`.
4. `.kernelet_entry_table` lies at `KW_TEXT + 0x1000` and its `size` and `version` fields are the ones OSTD (host build) was compiled against.
5. `.ex_table` and `.cpu_local` lie where the entry table's bounds say; `.cpu_local` ends the writable `PROGBITS` run, with only `.bss` after it.
6. The dependency closure of the kernelet image, from `cargo metadata`, contains `unsafe` only in crates on an allowlist. Every other crate is compiled with `-F unsafe_code` (`--forbid`, which a crate cannot override with an inner `allow`, unlike `-D`). The allowlist is `ostd` (kernelet build), `core`, `alloc`, `compiler_builtins`, `unwinding`, `ostd-pod`, and the third-party crates the closure already carries `unsafe` in today: `hashbrown`, `zerocopy`, `bitvec`, `intrusive-collections`, `spin`, `lru`, `smallvec` and `aster-util` (counted on the tree's dependency sources), each listed with a reason. So the property the audit establishes is "no `unsafe` outside an allowlist of fourteen crates", not "no `unsafe`"; the kernel proper's own crates are held to `forbid`. One loophole is accepted and named: the lint does not see `unsafe` that a macro from an allowlisted crate expands to in a `forbid` crate.
7. The entry table's source hash equals the host build's, recorded by OSDK from the OSTD source tree and the toolchain version, and compared again at registration.

The first five checks are what make invariants I1 and I3 properties of the artifact rather than of the source; the sixth is what makes "the kernel proper contains no `unsafe`" a statement about the build.
