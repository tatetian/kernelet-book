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

So the requirement is exact: **one exported symbol.**

```c
/* arch/x86/mm/pat/set_memory.c, after set_memory_x() */
EXPORT_SYMBOL_GPL(set_memory_x);
```

With it, `vmap(pages, n, VM_MAP, PAGE_KERNEL)` followed by `set_memory_x()` on the text pages alone gives an executable alias and leaves the data non-executable. Experiment 2 is that sequence.

## Experiment 3: the cost of reaching the kernelet

Three paths, measured by one program in one run inside the guest, timed with the processor's cycle counter so that the measurement makes no system calls while the task's system calls have been taken over:

| path | per call | over a bare call |
|---|---|---|
| a call Linux services itself | 46 ns | — |
| Syscall User Dispatch, no kernel change | 936 ns | +890 ns |
| the per-task hook, with the patch | 118 ns | +72 ns |

**7.9× cheaper with the patch.** On the build host, where a bare call costs 485 ns, the two no-patch alternatives that this chapter rejects measured 5,721 ns for seccomp user notification and 8,221 ns for `ptrace(PTRACE_SYSEMU)`, against 1,887 ns for Syscall User Dispatch on the same machine — the same ordering, five to eight times worse, for the same structural reason.

## The optional patch, in full

Twenty lines across four files, applied to v6.12 and booted for the measurement above:

```c
/* include/linux/sched.h — in struct task_struct */
#ifdef CONFIG_KERNELET_HOOK
	long	(*kernelet_syscall)(struct pt_regs *regs, long nr);
	void	*kernelet_ctx;
#endif

/* arch/x86/entry/common.c — at the top of do_syscall_64() */
#ifdef CONFIG_KERNELET_HOOK
	if (unlikely(current->kernelet_syscall)) {
		regs->ax = current->kernelet_syscall(regs, nr);
		instrumentation_end();
		syscall_exit_to_user_mode(regs);
		return false;
	}
#endif
```

plus an exported setter and a Kconfig entry. The [tenant page](tenant.md) gives the honest assessment of its upstream prospects, which is that it would need to be reframed as a generalization of Syscall User Dispatch to have a chance.

## What the build must check

The scheme rests on one property of the image that a person cannot verify by reading it, so the build checks it:

1. **The text segment carries no relocations.** One physical copy serves every instance, so nothing in the code may be patched per instance. Only the data segment may have relocation entries, and they must all be of the base-plus-offset kind.
2. **Code and data stay within reach of each other.** Program-counter-relative addressing on x86-64 reaches ±2 GB; the image's segments must be laid out inside that.
3. **The image imports nothing**, as the Design chapter's audit already requires.

## What is not shown

Stated plainly, because the chapter is a design and not a system.

- **No kernelet has run on either host.** Nothing of the kernelet design is built. What ran here is the mechanism each argument turns on, in isolation.
- **The two hosts' system-call costs have not been compared.** Linux mode's path is measured; Asterinas mode's `user_run` return is not measured anywhere in the book. Until it is, "which host is faster per system call" has no answer. **[unverified]**
- **The zero-copy argument has not been rechecked against Linux's block layer.** Its shape carries over; its numbers were derived for a host we control. **[unverified]**
- **The metadata address-space budget is arithmetic, not measurement.** The 16 GiB per instance on a 1 TiB machine, and the cap it implies on four-level paging, follow from the region sizes in Linux's documentation; no machine was filled with kernelets to check. **[unverified]**
- **The guest's absolute numbers are from a `tinyconfig` kernel** without the mitigations a production host runs. The ratios are the load-bearing part.
