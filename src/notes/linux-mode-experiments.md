# Linux-mode experiments

*Working material behind [Linux as the host](../blueprint/linux-mode/index.md): the programs, the kernel configuration, and the unedited output. Two machines are used and their numbers are never mixed. The **build host** is an Intel Xeon E3-1270 v6 running Linux 6.8.0-100-generic with the distribution's default speculative-execution mitigations; a bare system call costs 485 ns there. The **guest** is Linux 6.12.0 built from kernel.org sources with `tinyconfig` plus what QEMU and loadable modules need, booted under hardware virtualization on that host; a bare system call costs 44 ns there. Measured 2026-09-15; the guest figures below were re-measured after two defects in the patch were found in review, and are medians of five runs.*

## Building the guest kernel

```sh
curl -sSL -O https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.12.tar.xz
tar xf linux-6.12.tar.xz && cd linux-6.12
make tinyconfig
scripts/config --enable 64BIT --enable MODULES --enable MODULE_UNLOAD \
  --enable BLK_DEV_INITRD --enable RD_GZIP --enable PRINTK --enable MULTIUSER \
  --enable TTY --enable SERIAL_8250 --enable SERIAL_8250_CONSOLE \
  --enable BINFMT_ELF --enable PROC_FS --enable SYSFS --enable DEVTMPFS \
  --enable SMP --enable ACPI --enable PCI \
  --disable MODULE_SIG --disable SYSTEM_TRUSTED_KEYRING --disable INTEGRITY \
  --disable RANDOMIZE_BASE --disable RANDOMIZE_MEMORY
make olddefconfig && make -j8
```

`INTEGRITY` and `SYSTEM_TRUSTED_KEYRING` are disabled because they pull in the
certificate tooling, which needs OpenSSL headers this host does not have. Address-space
randomization is disabled so that the printed addresses are stable between runs; nothing
in the design depends on it being off.

Booted with:

```sh
qemu-system-x86_64 -enable-kvm -cpu host -nographic -no-reboot -m 1G -smp 2 \
  -kernel linux-6.12/arch/x86/boot/bzImage -initrd initrd.gz \
  -append "console=ttyS0 panic=1 quiet no_hash_pointers"
```

## Experiment 1: two copies of one module

`instdemo.c` declares one initialized global and one zeroed one, and prints their
addresses. `instdemo2.c` is the same file with the module renamed. Guest output:

```
instdemo [instdemo ]: &counter=ffffffffa0002000 counter=101 &scratch=ffffffffa0002440 text=ffffffffa0006000
instdemo2[instdemo2]: &counter=ffffffffa000c000 counter=101 &scratch=ffffffffa000c440 text=ffffffffa0010000
```

Both land in the module region, which begins at `0xffffffffa0000000`.

## Experiment 2: one physical text page, four instances

The gate for the chapter. `picdemo.c`:

```c
// Gate experiment: can one physical copy of position-independent text serve many
// instances, each reaching its OWN data through RIP-relative addressing?
//
// Layout per instance:  [ text page (shared) ][ data page (private) ]
// The text is  `mov rax, [rip+disp]; ret`  with disp chosen so it reads the first
// quadword of the page that follows it.  If the scheme works, calling through
// instance A's mapping must return A's datum and through B's must return B's,
// even though both mappings point at the SAME physical text page.
#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/vmalloc.h>
#include <linux/mm.h>
#include <linux/gfp.h>
#include <linux/string.h>
#include <linux/set_memory.h>

MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("one shared text, many private data, RIP-relative");

#define N_INST 4
typedef unsigned long (*fn_t)(void);

static struct page *ptext;
static struct page *pdata[N_INST];
static void *va[N_INST];

static int __init picdemo_init(void)
{
	/* 48 8b 05 <disp32>   mov rax, [rip+disp32]
	   c3                  ret                          -- 8 bytes, RIP after = +7 */
	u8 code[8] = { 0x48, 0x8b, 0x05, 0, 0, 0, 0, 0xc3 };
	u32 disp = PAGE_SIZE - 7;
	int i, pass = 1;

	ptext = alloc_page(GFP_KERNEL);
	if (!ptext)
		return -ENOMEM;
	memset(page_address(ptext), 0xcc, PAGE_SIZE);
	memcpy(code + 3, &disp, 4);
	memcpy(page_address(ptext), code, sizeof(code));

	pr_info("picdemo: one text page, pfn %#lx\n", page_to_pfn(ptext));

	for (i = 0; i < N_INST; i++) {
		struct page *pp[2];

		pdata[i] = alloc_page(GFP_KERNEL);
		if (!pdata[i])
			return -ENOMEM;
		*(unsigned long *)page_address(pdata[i]) = 0xda7a0000UL + i;

		pp[0] = ptext;		/* shared */
		pp[1] = pdata[i];	/* private */
		/* vmap() forces NX (mm/vmalloc.c: vmap_pages_range(..., pgprot_nx(prot), ...)),
		   so ask for a plain kernel mapping and then lift NX on the text page only. */
		va[i] = vmap(pp, 2, VM_MAP, PAGE_KERNEL);
		if (!va[i]) {
			pr_err("picdemo: vmap failed for instance %d\n", i);
			return -ENOMEM;
		}
```

Unedited guest output:

```
picdemo: one text page, pfn 0x76d
picdemo: instance 0 image at ffffc9000001d000  data at ffffc9000001e000  text pfn 0x76d
picdemo: instance 1 image at ffffc90000015000  data at ffffc90000016000  text pfn 0x76d
picdemo: instance 2 image at ffffc90000025000  data at ffffc90000026000  text pfn 0x76d
picdemo: instance 3 image at ffffc9000002d000  data at ffffc9000002e000  text pfn 0x76d
picdemo: instance stride = 0xffffffffffff8000 bytes
picdemo: call through instance 0 returned 0xda7a0000 (want 0xda7a0000) ok
picdemo: call through instance 1 returned 0xda7a0001 (want 0xda7a0001) ok
picdemo: call through instance 2 returned 0xda7a0002 (want 0xda7a0002) ok
picdemo: call through instance 3 returned 0xda7a0003 (want 0xda7a0003) ok
picdemo: RESULT PASS
```

The stride printed as a large unsigned value because `vmap()` returned the four ranges
out of order; the four base addresses above are what matter.

## Experiment 3: the cost of reaching the kernelet

`guest_bench.c` measures three paths in one run, calibrating the cycle counter against
`clock_gettime` first (3.792 cycles/ns in this guest) and then timing with `rdtsc`, so
that no measurement makes a system call while the task's system calls are taken over.
`hookdemo.ko` is a toy endovisor: it takes the task over through the patched hook,
answers `getppid` itself, and hands the task back after a fixed number of calls.

Guest output, five runs, in nanoseconds:

```
plain syscall           47  43  43  44  48     median  44
Syscall User Dispatch  926 938 929 927 961     median 929   (+885)
patched per-task hook   39  38  39  39  39     median  39   (24.0-24.9x cheaper than SUD)
```

The hook measures *faster* than a plain `getppid` because `hookdemo.ko` returns a
constant while `getppid` walks the task's parent pointer under a lock. The reading is
not "a kernelet is free": it is that the hook adds nothing measurable to Linux's entry
path.

**The first version of this measurement was wrong, and the error was in the patch, not
in the benchmark.** The hook returned `false` from `do_syscall_64`, which forces the
slow interrupt-return path and skips the checks that would have allowed the fast one.
That, not the hook, was most of the 118 ns first reported. The patch below is the
corrected version, which falls through to the common exit instead. The corrected hook
also tests `nr != -1`; without that test, attaching a kernelet would override a verdict
seccomp, ptrace or syscall user dispatch had already reached for that task.

Build-host output, for the two mechanisms this chapter rejects:

```
plain syscall                              485 ns
Syscall User Dispatch round trip          1887 ns   (+1402)
seccomp user notification round trip      5721 ns   (+5236)
ptrace PTRACE_SYSEMU round trip           8221 ns   (+7736)
```

## Experiment 4: where relocations actually land

The scheme requires that the **shared** part of the image carry no relocations, since one
physical copy serves every instance. Tested with a Rust staticlib built exactly as a
kernelet image would be (`-C relocation-model=pic -C code-model=small --target
x86_64-unknown-none`), containing the shapes a kernel image is full of: a table of trait
objects, a table of string slices, a table of function pointers, and address-free data.

Linked as a position-independent executable, which is what a kernelet image is:

```
rustc --crate-type=staticlib -C relocation-model=pic -C code-model=small \
      -C opt-level=2 --target x86_64-unknown-none -o libt.a t.rs
ld -pie --no-dynamic-linker -z norelro -e entry --whole-archive libt.a -o t.elf
```

`e_type` is `DYN`, there is no `DT_NEEDED`, and `.dynsym` holds only the null entry.

| section | size | relocations inside |
|---|---|---|
| `.text` | 274,307 B | **0** |
| `.rodata` | 64,914 B | **0** |
| `.data.rel.ro` | 4,192 B | 181 |
| `.got` | 952 B | 119 |
| `.got.plt` | 24 B | **0** |

All 300 are `R_X86_64_RELATIVE`. An earlier version of this measurement linked the same
objects with `-shared` and saw 331 relocations of three types, including 92
`R_X86_64_GLOB_DAT` and 3 `R_X86_64_64`. Those are an artifact of the shared-object link:
with everything defined inside the image and linked `-pie`, every reference resolves
internally and reduces to "add the load base".

A C build of the same shapes also puts one relocation in `.init_array` and one in
`.data`.

So the scheme holds, and the region table in the chapter's first draft was wrong.
Shareable: `.text` and `.rodata`, 339 KB of the 344 KB of read-only material, 98 percent.
Per-instance: `.got`, `.data.rel.ro`, `.init_array`, `.data`, `.cpu_local`, `.bss` —
about 5.2 KB of relocated material in this image. The first draft put `.init_array` in
the shared region and did not mention `.data.rel.ro` or `.got` at all.

A consequence: `.data.rel.ro` wants to be read-only *after* relocation, which on Linux
needs `set_memory_ro`, also unexported. Nothing breaks without it, so it is one of the
four exports a complete Linux mode wants rather than one of the pair it cannot start
without.

## Experiment 6: can kernel-mode code touch a tenant address?

`mod/smapdemo.c` plus `smap_test.c`. A user program holds a value in an ordinary
variable and asks a module to read it six ways, each in a forked child so that a case
which kills its task does not end the run. The module's ioctl runs on the caller's own
task, so `current->mm` is the tenant's.

The starting fact, checked in the Asterinas tree rather than in Linux: Asterinas does
**not** enable supervisor-access prevention. `ostd/src/arch/x86/mod.rs` sets OSFXSR,
OSXMMEXCPT, PAGE_GLOBAL, OSXSAVE and FSGSBASE in CR4, never SMAP, and nothing in the
tree emits `stac`/`clac`. Linux enables it wherever the hardware has it.

```
smap_test: the cell holds 5a5a5a5a5a5a5a5a at 0x4c70f0
  bare read        -> child KILLED by signal 9
  module-bracketed -> OK
  copy_from_user   -> OK
  direct-map alias -> OK
  bracketed, bad   -> child KILLED by signal 9
  bad, with fixup  -> OK          (smapdemo: recovered from the fault, fail=-14)
```

```
smapdemo: SMAP ENABLED in CR4
smapdemo: bare read of 00000000004c70f0 ...
BUG: unable to handle page fault for address: 00000000004c70f0
#PF: supervisor read access in kernel mode
Oops: Oops: 0001 [#1] SMP
smapdemo: bracketed read returned 5a5a5a5a5a5a5a5a
smapdemo: copy_from_user returned 5a5a5a5a5a5a5a5a
smapdemo: direct-map alias ffff88803ffdb0f0 returned 5a5a5a5a5a5a5a5a
smapdemo: bracketed read of unmapped 000003fffffff000 ...
BUG: unable to handle page fault for address: 000003fffffff000
Oops: Oops: 0000 [#2] SMP
```

What each case settles:

1. A bare kernel-mode read of a tenant address oopses on a page that is present,
   mapped and writable. The constraint is not about faulting pages in.
2. Code that is not Linux's own may bracket the access itself: `stac`/`clac` are
   kernel-mode instructions and a kernelet runs in kernel mode. "Only host code may
   touch user memory" is too strong.
3. Linux's own copy routine works, as expected.
4. The same value read through the supplier's own kernel alias works with **no
   bracket**, because that alias is not marked as user memory. `get_user_pages_fast`
   stands in here for the frame index a kernelet already keeps.
5. A bracketed read of a *bad* address oopses, and **the same read recovers when the
   faulting instruction carries an `_ASM_EXTABLE_TYPE_REG` entry** — it returns
   -EFAULT instead of faulting. The pair is the proof: the fixup mechanism works, and
   it works here only because the code is in a module, whose `__ex_table` Linux
   searches (`search_module_extables`, one of the three registrants in
   `kernel/extable.c`). A kernelet is not a module and cannot become one without
   giving up the shared text, so its table is never searched, and bracketing cannot
   deliver the *fallible* contract.

Hence D82's shape: an addressing rule, not a crossing. The kernel proper reaches
tenant memory through its own alias of the frames it granted; a crossing is needed
only on a miss.

## The failure that pinned down the requirement

Asking `vmap()` for executable memory and calling through it:

```
kernel tried to execute NX-protected page - exploit attempt? (uid: 0)
BUG: unable to handle page fault for address: ffffc9000001d000
#PF: supervisor instruction fetch in kernel mode
#PF: error_code(0x0011) - permissions violation
PTE 80000000008be163
Oops: Oops: 0011 [#1] SMP
```

Bit 63 of the page-table entry is the no-execute bit. `vmap()` sets it regardless of
what the caller asked for.

## The patch

```
Two changes to Linux that kernelet mode needs. Both were applied to v6.12 and
built and booted for the measurements in RESULTS.md.

1. Export set_memory_rox(), so an out-of-tree module can make a read-execute
   alias of pages it already owns. vmap() forcibly clears the execute bit and
   execmem_alloc() is not exported, so today there is no other way.

   set_memory_rox() and not set_memory_x(): the latter clears only the no-execute
   bit, leaving a mapping that is writable *and* executable, which is a W^X
   violation on a kernel that enforces it everywhere else. set_memory_rox()
   clears the write bit in the same call. Verified in the guest: the text page's
   entry prints W=0 X=1 afterward.

--- a/arch/x86/mm/pat/set_memory.c
+++ b/arch/x86/mm/pat/set_memory.c
@@ int set_memory_rox(unsigned long addr, int numpages)
 	return change_page_attr_clear(&addr, numpages, clr, 0);
 }
+EXPORT_SYMBOL_GPL(set_memory_rox);

   set_memory_rw() is this one's mandatory partner. set_memory_rox() also clears
   the write bit on the frames' alias in the direct map (cpa_process_alias() masks
   only _PAGE_NX out of the propagation), so a kind's text pages cannot go back to
   the page allocator until the permission is restored, and no permission setter
   is exported.

   Two more are wanted: set_memory_ro(), for the relocated read-only data, which
   is hardening; and get_vm_area(), because the frame-metadata region must be
   sparse and must grow, which vmap() cannot do. apply_to_page_range(), which
   populates such a range, is already exported.

   x86_fsbase_write_task() was on this list and is not needed: on the patched path
   the kernelet runs on the tenant's own task, so the module can set the saved
   field itself.

   A fourth was expected and is not needed. alloc_contig_range() IS exported
   (mm/page_alloc.c, as alloc_contig_range_noprof, plain EXPORT_SYMBOL, under
   CONFIG_CONTIG_ALLOC), as is free_contig_range(). What is not exported is
   alloc_contig_pages(), the wrapper that searches the zones for a suitable
   range, so a module can allocate long physical runs but must do the search
   itself. MAX_PAGE_ORDER is 10, so the plain page allocator stops at 4 MiB.

2. A per-task system-call hook, so a kernelet can service its tenant's calls
   without a trip through user space, and so that Linux's own system calls are
   out of the tenant's reach. About 25 lines across four files.

--- a/include/linux/sched.h
+++ b/include/linux/sched.h
@@ struct task_struct {
+#ifdef CONFIG_KERNELET_HOOK
+	/* Kernelet mode: when set, this task's system calls are serviced by a
+	 * kernelet inside the kernel instead of by Linux. */
+	long				(*kernelet_syscall)(struct pt_regs *regs, long nr);
+	void				*kernelet_ctx;
+#endif
 	struct thread_struct		thread;

--- a/arch/x86/entry/common.c
+++ b/arch/x86/entry/common.c
@@ __visible noinstr bool do_syscall_64(struct pt_regs *regs, int nr)
 	instrumentation_begin();
+#ifdef CONFIG_KERNELET_HOOK
+	/* nr == -1 means seccomp, ptrace or syscall user dispatch already
+	 * answered this call, so the kernelet must not be consulted and
+	 * regs->ax must stand. Falling through to the common exit below keeps
+	 * the fast return path; returning false here does not. */
+	if (unlikely(current->kernelet_syscall) && nr != -1) {
+		regs->ax = current->kernelet_syscall(regs, nr);
+	} else
+#endif
 	if (!do_syscall_x64(regs, nr) && !do_syscall_x32(regs, nr) && nr != -1) {

--- a/kernel/sys.c
+++ b/kernel/sys.c
@@ (end of file)
+#ifdef CONFIG_KERNELET_HOOK
+int kernelet_attach_current(long (*fn)(struct pt_regs *, long), void *ctx)
+{
+	current->kernelet_ctx = ctx;
+	smp_wmb();
+	current->kernelet_syscall = fn;
+	return 0;
+}
+EXPORT_SYMBOL_GPL(kernelet_attach_current);
+
+void kernelet_detach_current(void)
+{
+	current->kernelet_syscall = NULL;
+	smp_wmb();
+	current->kernelet_ctx = NULL;
+}
+EXPORT_SYMBOL_GPL(kernelet_detach_current);
+#endif

--- a/arch/x86/Kconfig
+++ b/arch/x86/Kconfig
+config KERNELET_HOOK
+	bool "Allow an in-kernel component to service a task's system calls"
+	depends on X86_64
```

## What is still wrong with the patch

Recorded rather than repaired, because each changes the size of the ask:

- **Only `do_syscall_64` is hooked.** A kernel with 32-bit compatibility also enters
  through `do_int80_emulation`, `do_fast_syscall_32` and `do_SYSENTER_32`. A tenant
  could use any of them and have its call serviced by Linux, invisibly to the kernelet.
  The test guest had compatibility compiled out, so this could not appear in the
  measurement.
- **No lifetime management.** `fork` copies the two fields into the child, nothing
  clears them at exit, and nothing takes a reference on the module.
- **The return-value convention is unstated.** Several negative values mean *restart
  this call* to Linux's signal machinery.
- **Upstream prospects.** Not as posted. A version with a chance would be framed as a
  generalization of Syscall User Dispatch, with an in-kernel dispatch target instead of
  a signal, an in-tree user, and the lifetime rules worked out.

## Experiment 5: can a kernelet image satisfy indirect-branch tracking?

Half of it, and the half that can is a compiler flag.

- In the default build, the crate's own functions carry no `endbr64`. The 35 in the
  binary come from the prebuilt `core` shipped for the target.
- With `-Z cf-protection=branch`, `entry` begins with `f3 0f 1e fa`, which is `endbr64`.
  So the compiler emits the markers on demand, at the cost of an unstable flag.
- Neither build emits a `.note.gnu.property` declaring the property, because the
  prebuilt `core` does not. A kernelet image would need `core` rebuilt with the same
  flag for the whole image to be marked.

What this does **not** settle, and why A19 stays open: whether a kernel that rewrites
indirect call sites into a stricter per-signature form can do so in text that every
instance of a kind shares. The rewrite happens once, at load, to one physical copy,
which is consistent with sharing; that the kernel's rewriter can be pointed at an image
the endovisor loaded itself is untested.

## Pitfalls met along the way, recorded so they are not met twice

- A `SIGSYS` handler for Syscall User Dispatch must leave the selector byte reading
  *allow* before it returns, or the `rt_sigreturn` that ends the handler is itself
  diverted and the process dies on an uncaught `SIGSYS`.
- `PTRACE_SYSEMU` intercepts *every* call including `exit_group`, so a benchmark that
  emulates them all never lets its child terminate.
- Building modules against a kernel tree needs the full build, not `modules_prepare`:
  `Module.symvers` is produced by the main build and without it every symbol is
  reported undefined.
- A hook in `do_syscall_64` must not return `false` to signal *handled*. That value
  means *leave through the interrupt-return path*, which costs more than the hook
  itself and hides the result being measured.
- The test processor predates indirect-branch tracking. The eight-byte position-
  independent toy has no landing instruction at its entry, so on a processor with the
  feature enabled the same experiment would fault rather than pass.

## The module and the program of Experiment 6

```c
/* mod/smapdemo.c — six ways to read a tenant's memory, on the caller's task */
	case SMAP_BARE:
		v = *(volatile const unsigned long *)p;        /* no bracket  */
	case SMAP_STAC:
		stac(); v = *(volatile const unsigned long *)p; clac();
	case SMAP_COPY:
		copy_from_user(&v, p, sizeof(v));
	case SMAP_ALIAS: {
		struct page *pg;
		get_user_pages_fast((unsigned long)p & PAGE_MASK, 1, 0, &pg);
		v = *(volatile unsigned long *)((char *)page_address(pg) + off);
		put_page(pg);
	}
	case SMAP_BAD:                                     /* unmapped user address */
		stac(); v = *(volatile const unsigned long *)0x3fffffff000UL; clac();
	case SMAP_FIXUP:                                   /* the same, with a fixup */
		stac();
		asm volatile("1: movq (%[addr]), %[val]\n2:\n"
			     _ASM_EXTABLE_TYPE_REG(1b, 2b, EX_TYPE_EFAULT_REG, %[fail])
			     : [val] "=r" (v), [fail] "+r" (failed) : [addr] "r" (bad));
		clac();
```

The program runs each case in a forked child and reports whether the child returned or
was killed, so that the two cases which oops do not end the run. The guest was booted
with `-cpu host` on a Kaby Lake, so the hardware check is present and the module prints
that it is enabled in CR4.
