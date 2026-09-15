# Evidence

*What was built, what was run, and what is still argued rather than shown. Three experiments and one patch, all against Linux 6.12 built from kernel.org sources for this chapter. The raw transcripts and the sources are in [Linux-mode experiments](../../notes/linux-mode-experiments.md) in The Notes.*

## The setting

Two machines are involved and the difference matters.

The **build host** is an Intel Xeon E3-1270 v6 running Linux 6.8 with the default speculative-execution mitigations. A bare system call there costs 485 ns. This is where the mechanisms that need no kernel change were measured, because they need no kernel change.

The **guest** is Linux 6.12.0, configured from `tinyconfig` plus what a virtual machine and loadable modules need, booted under hardware virtualization on the same host. A bare system call there costs 46 ns, because the configuration carries none of the mitigations. This is where the patched paths were measured, and where all three yes-or-no experiments ran.

Absolute numbers from the two are not comparable and are never mixed below. Ratios are, and they agree.

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

## What Linux refused, and the one line that fixes it

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

So a symbol must be exported — and the first version of this page named the wrong one. `set_memory_x` clears only the no-execute bit, and `vmap()` returns a **read-write** mapping, so the result is memory that is writable *and* executable: a W^X violation rather than the read-execute the design wants. The right primitive clears both bits at once:

```c
/* arch/x86/mm/pat/set_memory.c, after set_memory_rox() */
EXPORT_SYMBOL_GPL(set_memory_rox);
```

With it, `vmap(pages, n, VM_MAP, PAGE_KERNEL)` followed by `set_memory_rox()` on the text pages alone gives a read-execute alias and leaves the data writable and non-executable. The module prints the resulting page-table entry to show it:

```
picdemo: instance 0 text pte 0x73e121  W=0 X=1
```

One reviewer objection is worth closing here, because the answer is in Linux's own source. Does making the alias executable also make the **direct map** executable, handing every module a way around W^X? No: the code that propagates attribute changes to the direct-map alias masks the execute bit out first, with the comment *"Directmap always has NX set, do not modify"*. What it does cost is on the next line — a machine-wide translation-buffer flush per call, so per instance created.

And the honest total: **this is not the only export Linux mode needs.** Allocating grains larger than the page allocator's maximum order needs the contiguous allocator, which is not exported; making `.data.rel.ro` read-only after relocation needs `set_memory_ro`, which is not exported; and a tenant's thread-local storage needs the helper that writes a task's segment base, which is not exported either. The hard requirement for the scheme in this chapter is one symbol. The requirement for a complete Linux mode is at least three.

## Experiment 3: the cost of reaching the kernelet

Three paths, measured by one program in one run inside the guest, timed with the processor's cycle counter so that the measurement makes no system calls while the task's system calls have been taken over. Medians of five runs, with the spread, because a single run of this varies by about fifteen percent:

| path | median | spread | over a bare call |
|---|---|---|---|
| a call Linux services itself | 44 ns | 43–48 | — |
| Syscall User Dispatch, no kernel change | 929 ns | 926–961 | +885 ns |
| the per-task hook, with the patch | 39 ns | 38–39 | below the noise |

The hook measures below a bare `getppid` because the servicer returns a constant while `getppid` does work; what it shows is that the hook adds nothing measurable to the entry path.

**The first version of these numbers was wrong, and the error was in the patch, not the measurement.** The hook returned a value meaning *leave through the slow exit path*, which forced every serviced call out through the expensive return and skipped the checks that would have permitted the cheap one. That accounted for most of the 118 ns first reported. With the hook falling through to Linux's ordinary exit, the same measurement gives 39 ns, and the difference against Syscall User Dispatch is about **24×**, not the 7.9× first published. The same review found that the hook did not test for the marker meaning *an earlier stage already answered this call*, so it would have overridden a tenant's seccomp verdict; that is fixed too.

The two no-patch alternatives this chapter rejects were measured on the build host, where a bare call costs 485 ns: 5,721 ns for seccomp user notification and 8,221 ns for `ptrace(PTRACE_SYSEMU)`, against 1,887 ns for Syscall User Dispatch on that same machine — 3.0× and 4.4× more, for the same structural reason. Numbers from the two machines are not compared with each other anywhere in this chapter.

## The optional patch, in full

Twenty lines across four files, applied to v6.12 and booted for the measurement above:

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

plus an exported setter and a configuration entry. What it still lacks is listed on the [tenant page](tenant.md): the three other entry points, lifetime management across `fork` and exit, a reference on the module, and a stated convention for the values that mean *restart this call*. The honest assessment of its upstream prospects is there too.

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
- **The gate experiment ran on a processor without indirect-branch tracking.** Newer processors, with the same kernel, refuse an indirect call whose target is not marked as a legal landing point. The toy's eight bytes carry no such marker, so on such a machine it would fault. This matters far beyond the toy: the whole design is indirect calls, through the service table and the entry table, so a kernelet image must be built to emit those markers, and on a kernel that rewrites them into a checked form it must match that scheme. Nothing in this chapter or the build audit addresses it. **[unverified]**
- **The tenant's process lifecycle is not designed**, as the [tenant page](tenant.md) says. Nor is the handling of the virtual system-call page.
- **Invariant I7 does not hold on Linux.** A task in kernel mode cannot be forcibly stopped.
- **The two hosts' system-call costs have not been compared.** Linux mode's path is measured; Asterinas mode's `user_run` return is not measured anywhere in the book. Until it is, "which host is faster per system call" has no answer. **[unverified]**
- **The zero-copy argument has not been rechecked against Linux's block layer.** Its shape carries over; its numbers were derived for a host we control. **[unverified]**
- **The metadata address-space budget is arithmetic, not measurement.** The 16 GiB per instance on a 1 TiB machine, and the cap it implies on four-level paging, follow from the region sizes in Linux's documentation; no machine was filled with kernelets to check. **[unverified]**
- **The guest's absolute numbers are from a `tinyconfig` kernel** without the mitigations a production host runs. The ratios are the load-bearing part.
