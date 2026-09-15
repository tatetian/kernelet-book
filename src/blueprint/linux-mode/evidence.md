# Evidence

*What was built, what was run, what is still argued rather than shown, and the order in which the rest should be attacked. Six experiments and one patch. The kernel work is against Linux 6.12, built from kernel.org sources for this chapter; three of the measurements in Experiment 3 were taken on the build host's own 6.8 kernel, and are kept apart from the rest. The raw transcripts and the sources are in [Linux-mode experiments](../../notes/linux-mode-experiments.md) in The Notes.*

## The setting

Two machines are involved and the difference matters.

The **build host** is an Intel Xeon E3-1270 v6 running Linux 6.8 with the default speculative-execution mitigations. A bare system call there costs 485 ns. This is where the mechanisms that need no kernel change were measured, because they need no kernel change.

The **guest** is Linux 6.12.0, configured from `tinyconfig` plus what a virtual machine and loadable modules need, booted under hardware virtualization on the same host. A bare system call there costs 44 ns, because the configuration carries none of the mitigations. This is where the patched paths were measured, and where every yes-or-no experiment ran.

Absolute numbers from the two are not comparable and are never mixed below. Neither are ratios taken against them: a floor ten times lower flatters every ratio measured against it, so the guest's ratios are reported as the guest's and nothing is carried across.

## Experiment 1: two instances of one image, each with its own data

The same module source built under two names, both loaded at once:

```
instdemo [instdemo ]: &counter=ffffffffa0002000 counter=101 &scratch=ffffffffa0002440
instdemo2[instdemo2]: &counter=ffffffffa000c000 counter=101 &scratch=ffffffffa000c440
```

Each copy has its own initialized and zeroed data at its own address, and each ran its own initializer — both read 101 from a shared starting value of 100. Linux rejects a second copy of a module on the **name** alone, so this is bookkeeping rather than anything deeper. *Shows:* relocating one image twice gives two independent sets of globals.

## Experiment 2: one physical text page, four instances

The gate for the whole chapter. One page of position-independent text containing eight bytes of machine code, `mov rax, [rip+disp]; ret`, with the displacement chosen to read the page that follows. That one physical page is mapped four times, each followed by a different data page.

```
picdemo: one text page, pfn 0x76d
picdemo: instance 0 image at ffffc9000001d000  data at ffffc9000001e000  text pfn 0x76d
picdemo: instance 1 image at ffffc90000015000  data at ffffc90000016000  text pfn 0x76d
picdemo: instance 2 image at ffffc90000025000  data at ffffc90000026000  text pfn 0x76d
picdemo: instance 3 image at ffffc9000002d000  data at ffffc9000002e000  text pfn 0x76d
picdemo: call through instance 0 returned 0xda7a0000 (want 0xda7a0000) ok
picdemo: call through instance 1 returned 0xda7a0001 (want 0xda7a0001) ok
picdemo: call through instance 2 returned 0xda7a0002 (want 0xda7a0002) ok
picdemo: call through instance 3 returned 0xda7a0003 (want 0xda7a0003) ok
picdemo: RESULT PASS
```

*Shows:* one shared copy of position-independent code, executed through four different mappings, reaches four different instances' data, selected by the program counter with no register, no table and no lookup. This is [the scheme](one-address-space.md) in its entirety.

## What Linux refused, and the two lines that fix it

The first attempt asked `vmap()` for executable memory and got a kernel that would not execute it:

```
kernel tried to execute NX-protected page - exploit attempt? (uid: 0)
BUG: unable to handle page fault for address: ffffc9000001d000
#PF: supervisor instruction fetch in kernel mode
PTE 80000000008be163          <- bit 63 set: no-execute
```

Three facts in the source explain it and close every alternative:

- `vmap()` wraps the caller's permissions in `pgprot_nx()`, which clears the execute bit ([`mm/vmalloc.c`](https://elixir.bootlin.com/linux/v6.12/source/mm/vmalloc.c#L3453)).
- [`arch/x86/mm/pat/set_memory.c`](https://elixir.bootlin.com/linux/v6.12/source/arch/x86/mm/pat/set_memory.c) exports helpers that change caching and **none** that change permissions.
- `execmem_alloc()`, which replaced `module_alloc()` in v6.12, has no export at all, and on x86-64 it is confined to the 1520 MB module region with no fallback.

So a symbol must be exported — two, as it turns out — and it is easy to name the wrong one. `set_memory_x` clears only the no-execute bit, and `vmap()` returns a **read-write** mapping, so the result is memory that is writable *and* executable: a W^X violation rather than the read-execute the design wants. The right primitive clears both bits at once:

```c
/* arch/x86/mm/pat/set_memory.c, after set_memory_rox() */
EXPORT_SYMBOL_GPL(set_memory_rox);
```

With it, `vmap(pages, n, VM_MAP, PAGE_KERNEL)` followed by `set_memory_rox()` on the text pages alone gives a read-execute alias and leaves the data writable and non-executable. The module prints the resulting page-table entry to show it:

```
picdemo: instance 0 text pte 0x73e121  W=0 X=1
```

One reviewer objection is worth closing here, because the answer is in Linux's own source. Does making the alias executable also make the **direct map** executable, handing every module a way around W^X? No: the code that propagates attribute changes to the direct-map alias masks the execute bit out first, with the comment *"Directmap always has NX set, do not modify"*. What it does cost is on the next line — a machine-wide translation-buffer flush per call, so per instance created.

And the honest total: **this is not the only export Linux mode needs.** Four symbols were checked in the v6.12 tree, of which the first two are mandatory:

| symbol | exported today? | what needs it |
|---|---|---|
| `set_memory_rox` | **no** | making a kernelet's text read-execute; nothing works without it |
| `set_memory_rw` | **no** | giving those frames back. The call above makes them read-only in the host's direct map too, so releasing a kind without restoring the permission hands the next user a read-only page. The mandatory partner of the first |
| `set_memory_ro` | **no** | making the relocated read-only data read-only again after the loader has patched it. Hardening, not function |
| `get_vm_area` | **no** | reserving a kernel range to populate sparsely, which is what keeps the frame-metadata check ([one address space](one-address-space.md)). Populating it needs `apply_to_page_range`, which **is** exported; nothing else that would do the job is |

Two things this page once asked for do not belong on the list. `alloc_contig_range` **is** exported, so long runs of physical memory are available to a module after all; only the wrapper that searches for a range is not, so the endovisor does that search itself. And writing a tenant thread's thread-pointer register needs no export: on the patched path the kernelet runs on the tenant's own task, so the module can set the field and write the register itself, which is ten lines of duplicated logic rather than a missing capability.

So the hard requirement is a pair of symbols, and a complete Linux mode wants four.

## Experiment 3: the cost of reaching the kernelet

Three paths, measured by one program in one run inside the guest, timed with the processor's cycle counter so that the measurement makes no system calls while the task's system calls have been taken over. Medians of five runs, with the spread, because a single run of this varies by about fifteen percent:

| path | median | spread | over a bare call |
|---|---|---|---|
| a call Linux services itself | 44 ns | 43–48 | — |
| Syscall User Dispatch, no kernel change | ≥929 ns | 926–961 | +885 ns |
| the per-task hook, with the patch | 39 ns | 38–39 | below the noise |

The hook measures below a bare `getppid` because the servicer returns a constant while `getppid` does work; what it shows is that the hook adds nothing measurable to the entry path.

**An earlier version of these numbers was published and was wrong, so a reader may be holding it.** The error was in the patch, not the measurement: the hook returned a value meaning *leave through the slow exit path*, which forced every serviced call out through the expensive return and skipped the checks that would have permitted the cheap one. That accounted for most of the 118 ns first reported. With the hook falling through to Linux's ordinary exit, the same measurement gives 39 ns. The same review found that the hook did not test for the marker meaning *an earlier stage already answered this call*, so it would have overridden a tenant's seccomp verdict; that is fixed too.

The two no-patch alternatives this chapter rejects were measured on the build host, where a bare call costs 485 ns: 5,721 ns for seccomp user notification and 8,221 ns for `ptrace(PTRACE_SYSEMU)`, against 1,887 ns for Syscall User Dispatch on that same machine — 3.0× and 4.4× more, for the same structural reason. Numbers from the two machines are not compared with each other anywhere in this chapter.

## Experiment 4: where the relocations land

Not a kernel experiment: a Rust staticlib, built with the flags a kernelet image would use, examined with `readelf`. It answers the question Experiment 2 cannot, which is whether a *real* image's shared regions are free of addresses.

| section | size | relocations inside |
|---|---|---|
| `.text` | 274,307 B | **0** |
| `.rodata` | 64,914 B | **0** |
| `.data.rel.ro` | 4,192 B | 181 |
| `.got` | 952 B | 119 |

The library is linked the way a kernelet image is: a position-independent executable, with no dynamic linker, no imports, and every symbol defined inside it.

*Shows:* 98 percent of the read-only material is address-free and therefore shareable, and everything that must be patched per instance is a few kilobytes. All 300 relocations are of a single type, the base-relative fixup, so the host's relocation loop has one case rather than three — which is why the [build audit](../design/builds-and-images.md#audit) can require that type and refuse the rest. The shapes tested — tables of trait objects, of string slices and of function pointers — are the ones a kernel image is full of, but this is a synthetic library and not the kernelet image, which does not exist. **[unverified]** as a statement about the real image.

## Experiment 5: indirect-branch markers

The design is indirect calls, so the image must be acceptable to a processor that checks them. Two things were tried on the same library as Experiment 4.

In the ordinary build, the library's own functions carry no landing marker; the 35 in the binary come from the prebuilt standard library. Compiled with the unstable flag that asks for them, the entry function begins with the four bytes that are the marker.

Neither build declares the property that a *user-space* loader reads before enabling the check for a process. That note is irrelevant here, because in kernel mode the check is enabled machine-wide and only the instructions matter — but it is why the standard library must be rebuilt: its compiled code lacks the instructions, not the note.

*Shows:* the compiler half of the problem has an answer, and it costs an unstable flag and a rebuilt standard library. The kernel half is where the risk is, and [one address space](one-address-space.md) states it: on a host whose own build enforces the type-checked form, a kernelet's entry functions need preambles the host's compiler would accept, and the first call into a kernelet traps without them. Assumption A19. **[unverified]**

## Experiment 6: can kernel-mode code touch a tenant address?

Six cases, on the caller's own task, in the guest, with the hardware's user-access check enabled in the control register. A user-space program holds a value in an ordinary variable and asks a module to read it six ways; each case runs in a forked child, so that a case which kills its task does not end the run.

```
smap_test: the cell holds 5a5a5a5a5a5a5a5a at 0x4c70f0
  bare read        -> child KILLED by signal 9
  module-bracketed -> OK
  copy_from_user   -> OK
  direct-map alias -> OK
  bracketed, bad   -> child KILLED by signal 9
  bad, with fixup  -> OK          (smapdemo: recovered from the fault, fail=-14)
```

and, in the kernel's log:

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

*Shows:* four things, in order of how much they change the design.

1. **A bare kernel-mode read of a tenant address ends the task**, on a page that is present, mapped and writable. The constraint has nothing to do with faulting pages in.
2. **Code that is not Linux's own may bracket the access itself.** Those are kernel-mode instructions and a kernelet runs in kernel mode. So "only host code may touch user memory" is too strong.
3. **The same value read through the supplier's own kernel alias needs no bracket at all**, because that alias is not marked as user memory.
4. **A bracketed read of a bad address ends the task**, and **the same read recovers when the faulting instruction has a fixup entry** — it returned the error code for a bad address instead of faulting. The pair is the point: recovery works here only because the code is in a *module*, and Linux searches the loaded modules' tables. A kernelet is not a module and cannot become one without giving up the shared text, so its own table is never searched. That is why bracketing cannot deliver the *fallible* contract the kernel proper needs.

Together those say the rule is an addressing rule and not a crossing, which is [decision D82](not-as-assumed.md). One more fact makes it a finding about the API rather than about Linux: **Asterinas does not enable the check.** Its control-register setup names five bits and not that one, and nothing in its tree emits the bracketing instructions. The same source therefore works on one host and faults on the other, and nothing in the API or its taxonomy mentions the requirement. The [Design chapter now states it](../design/virtualizing-ostd/user-mode.md).

## The patch, in full

About twenty-five lines across four files, applied to v6.12 and booted for Experiment 3:

```c
/* include/linux/sched.h — in struct task_struct */
#ifdef CONFIG_KERNELET_HOOK
	long	(*kernelet_syscall)(struct pt_regs *regs, long nr);
	void	*kernelet_ctx;
#endif

/* arch/x86/entry/common.c — in do_syscall_64(), replacing the dispatch.
   nr == -1 means seccomp, ptrace or syscall user dispatch already answered,
   so the kernelet must not be consulted and regs->ax must stand. Falling
   through to the common exit keeps the fast return path. */
#ifdef CONFIG_KERNELET_HOOK
	if (unlikely(current->kernelet_syscall) && nr != -1) {
		regs->ax = current->kernelet_syscall(regs, nr);
	} else
#endif
	if (!do_syscall_x64(regs, nr) && !do_syscall_x32(regs, nr) && nr != -1) {
		regs->ax = __x64_sys_ni_syscall(regs);
	}
```

plus an exported setter and a configuration entry. What it still lacks is listed on the [tenant page](tenant.md): the other entry points, lifetime management across `fork` and exit, a reference on the module, and a stated convention for the values that mean *restart this call*. The honest assessment of its upstream prospects is there too.

## What the build must check

The scheme rests on one property of the image that a person cannot verify by reading it, so the build checks it:

1. **The shared regions carry no relocations.** One physical copy of `.text` and `.rodata` serves every instance, so nothing in them may be patched per instance. Every relocation must fall in the per-instance region.
2. **Code and data stay within reach of each other.** Program-counter-relative addressing on x86-64 reaches ±2 GB; the image's segments must be laid out inside that.
3. **The image imports nothing**, as the Design chapter's audit already requires.
4. **Every indirect-branch target is marked**, so that the image runs on a processor with indirect-branch tracking enabled.

Checks 1 and 4 replace the audit's earlier requirement that the image be a fixed-address executable with no relocations at all, which the revised decision makes impossible: a position-independent image has relocations by construction, and what matters is *where* they land.

## What is not shown

Stated plainly, because the chapter is a design and not a system.

- **No kernelet has run on either host.** Nothing of the kernelet design is built. What ran here is the mechanism each argument turns on, in isolation.
- **The gate experiment ran on a processor without indirect-branch tracking**, so the toy's unmarked eight bytes were accepted where a newer machine would fault. Experiment 5 settles the compiler half of that question and leaves the kernel half open. **[unverified]**
- **The tenant's process lifecycle is not designed**, as the [tenant page](tenant.md) says. Nor is the handling of the virtual system-call page.
- **Invariant I7 does not hold on Linux.** A task in kernel mode cannot be forcibly stopped.
- **The two hosts' system-call costs have not been compared.** Linux mode's path is measured; Asterinas mode's `user_run` return is not measured anywhere in the book. Until it is, "which host is faster per system call" has no answer. **[unverified]**
- **The zero-copy argument has not been rechecked against Linux's block layer.** Its shape carries over; its numbers were derived for a host we control. **[unverified]**
- **The metadata address-space budget is arithmetic, not measurement.** The 16 GiB per instance on a 1 TiB machine, and the cap it implies on four-level paging, follow from the region sizes in Linux's documentation; no machine was filled with kernelets to check. **[unverified]**
- **The guest's absolute numbers are from a `tinyconfig` kernel** without the mitigations a production host runs, so its floor is about a tenth of a production host's. What carries is the overhead each mechanism adds, not the ratio against that floor.
- **How often the alias rule misses is not known.** Experiment 6 settles what the kernel proper may and may not dereference; how often it will hold no alias for an address its tenant touches is a property of workloads, and nothing here measures it. **[unverified]**

## What to build first

The chapter names more open items than a reader can hold in order, and they are not equal: some block the first line of code and some block the second process. This is the order they should be attacked in, and what each stage is gated on.

**1. Settle the branch-tracking question on the configuration that ships.** Put a landing marker in front of the eight bytes of Experiment 2 and run it on a distribution kernel with plain indirect-branch tracking enabled. Experiment 5 showed the compiler emits the marker; nothing has yet shown a kernelet-shaped indirect call *lands* on a kernel that enforces it. That is an hour on hardware already to hand (*estimated*), and it covers every machine an operator would deploy on. The stricter, type-checked form is a scoping question rather than a gate, because it needs a kernel built with a different compiler than distributions use, and most of it is answerable without a kernel at all: compile one function with each toolchain's type-hash option and compare the two constants. If they disagree, no kernel work fixes it (assumption A19).

**2. The loader.** Export the permission pair, assemble an instance's range, relocate it, and enter a kernelet image that initializes vOSTD far enough to write a line through the log service call and stop. Nothing on this path is open; what it proves is that the [one-address-space scheme](one-address-space.md) works on a real image rather than on eight bytes.

**3. Memory.** The metadata region, which needs the fourth export and is where invariant I3's last hardware check lives; grains from the page allocator; the owner array; the kernel proper's own allocator running over granted frames. Gated on step 2.

**4. Tasks, interrupts, time, devices.** Kernel threads, wait queues, workqueues and high-resolution timers cover almost all of it, and the [what differs](what-differs.md) tables say so: this is the twelve-row half of the design that Linux answers without argument. The exception is the per-CPU selector, which needs the framework's preemption count to become a real host preemption disable before any of this is safe, since a kernelet's own threads use it too. Gated on step 3.

**5. The tenant.** The system-call hook, the stack switch, the migration hold on the tenant's task, and the alias rule for tenant memory with the invalidation callback that keeps its map true. This stage is where the first system call that passes a buffer works, and where the miss rate Experiment 6 left open gets its number. Gated on everything above.

Process lifecycle, which the chapter calls its largest open item, is deliberately last: it blocks a tenant's *second* process, not its first, and a single-process tenant is enough to measure everything in stage 5.
