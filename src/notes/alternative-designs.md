# Alternative designs: what was measured, and what was checked

*Working material behind [Alternative designs](../blueprint/alternatives/index.md). Three of that chapter's designs were built and run rather than argued; their unedited transcripts are here. So is a second symbol table, in the form [Linux-mode experiments](linux-mode-experiments.md) uses, covering the claims the designs turn on. Everything ran on the same two machines as the earlier chapter: the **build host** is an Intel Xeon E3-1270 v6 on Linux 6.8, and the **guest** is Linux 6.12 built from kernel.org sources, booted under hardware virtualization on it.*

## A warning about the tree

The kernel tree these experiments used carries the previous chapter's own two changes: an added export of the read-execute permission setter, and the per-task system-call hook, across `arch/x86/mm/pat/set_memory.c`, `include/linux/sched.h`, `arch/x86/entry/common.c`, `kernel/sys.c` and `arch/x86/Kconfig`. Pristine copies of those five files were extracted from the release tarball for comparison. One agent read the patched tree and reported that the chapter's mandatory export was already upstream; it is not. Any claim about those five files has to be checked against the pristine copies, and the tree's symbol file is filtered by a minimal configuration, so a symbol's absence from it means nothing.

## Experiment 8: a supervisor-only alias of a tenant's page

The mechanism of the [supervisor alias](../blueprint/alternatives/whole-mode.md#alias). A module finds a free top-level index in the tenant's own address space, copies the tenant's top-level entry into it with the user bit cleared and the no-execute bit set, and reads the tenant's value through the resulting kernel address.

```
aliasdemo: 5-level paging off (folded to 4), PGDIR_SHIFT=39, PTRS_PER_PGD=512, SMAP ENABLED in CR4
aliasdemo: free kernel PGD index 274, ALIAS_BASE=ffff890000000000
aliasdemo: tenant 00000000004c70f0 pgd[  0]=00000000009a4067 P=1 U=1 W=1 NX=0
aliasdemo: tenant 00000000004c70f0 pte     =840000003fe4a005 P=1 U=1 W=0 NX=1 pfn=3fe4a
aliasdemo: spliced 00000000009a4067 -> 80000000009a4063 (_PAGE_USER cleared, _PAGE_NX set)
aliasdemo: alias  ffff8900004c70f0 pgd[274]=80000000009a4063 P=1 U=0 W=1 NX=1
aliasdemo: alias  ffff8900004c70f0 pud     =0000000000980067 P=1 U=1 W=1 NX=0
aliasdemo: alias  ffff8900004c70f0 pte     =840000003fe4a005 P=1 U=1 W=0 NX=1 pfn=3fe4a
aliasdemo: bare read of alias returned 5a5a5a5a5a5a5a5a
alias_test: in-task ALIAS_RUN returned 0; cell now 5555555555555555 (expect 5555555555555555)
aliasdemo: CONTROL bare read of tenant 00000000004c70f0 ...
Oops: Oops: 0001 [#2] SMP
alias_test: CONTROL child KILLED by signal 9
```

Read the walk: only the spliced top-level entry has the user bit clear, and every level beneath it is the tenant's own, unchanged and still user-accessible. The frame is the same in both walks. The control is the same read of the same frame through the tenant's own address, on the same task in the same run, and it takes a fault and kills the child. That is the hardware's rule observed rather than inferred from Linux's page-table dumper.

The cost, two hundred thousand iterations with interrupts disabled:

```
aliasfault: BENCH n=200000  kernel-addr 216062 cyc (1.08/op)  alias 185154 cyc (0.92/op)
                            get_user 7649772 cyc (38.24/op)  acc=37d09df0
```

So the alias is free and bracketing is not. A fault on an *alias* address with a fixup recovered and printed no oops, which is what shows the kernel-half path runs the ordinary fixup search.

## Experiment 9: two tenant threads on one carrier task

The mechanism of [carriers](../blueprint/alternatives/whole-mode.md#carriers). One Linux task carries two tenant threads, swapping the register file, the thread pointer and the floating-point state between them, four hundred thousand times.

```
A: glibc fs=0x3c69c3c0  tls_a=0x7f55f02bb000  tls_b=0x7f55f02ba000  thread_b=0x401820
A: iterations=1000  A tls counter=1000  B tls counter=1000
A: live xmm0=0xaaaa0000000003e8 (expected 0xaaaa0000000003e8)   B saw sentinel: 0
T: tsc calibration 3.792 cycles/ns
T: plain getppid, Linux services it            43 ns
T: bare hook, no thread switch                 39 ns
T: carrier switch  + pt_regs only             169 ns  (+131 vs bare hook)
T: carrier switch  + FS base                  239 ns  (+200 vs bare hook)
T: carrier switch  + FPU (the whole user context) 330 ns  (+291 vs bare hook)
T: 400000 serviced calls timed per row
A: survived #DE, rax=0xdead (0xdead means the die notifier answered)
```

Two thread-local counters each reach their own total and the floating-point register survives the swap, so the contexts really are separate. The timing row that matters is the last: a switch costs 291 nanoseconds more than a serviced call that stays on the same thread, and the decomposition says the floating-point state is 91 of it. The final line is the answer to the fourth entry point: a tenant's division error was caught by a trap notifier and the tenant resumed.

## Experiment 7: the fallible contract with no patch

Already recorded in [Linux-mode experiments](linux-mode-experiments.md). A die notifier holding a module's own one-entry table recovered a bracketed fault on a bad user address, twice, with the process surviving — and printed a full oops each time, which is why it is the answer for a bug and not for a contract.

## Symbols and facts the designs turn on

Read in the tree, with the configuration gate where there is one. This table is to the alternatives chapter what the symbol table in [Linux-mode experiments](linux-mode-experiments.md) is to the previous one.

| fact or symbol | where | state |
|---|---|---|
| one hook covers every system-call entry | `kernel/entry/common.c:28`, `syscall_trace_enter` | reached by every x86 entry through `syscall_enter_from_user_mode[_work]`; generic entry is selected by x86, s390, riscv, loongarch |
| the marker an earlier stage sets | same function, `:39` dispatch, `:45` ptrace, `:52` seccomp | the order is dispatch, ptrace, seccomp; the convention is a return of −1 |
| `__register_binfmt`, `unregister_binfmt` | `fs/exec.c:96`, `:105` | `EXPORT_SYMBOL` |
| `begin_new_exec`, `setup_new_exec`, `setup_arg_pages`, `finalize_exec`, `set_binfmt` | `fs/exec.c` | all exported |
| `start_thread` | `arch/x86/kernel/process_64.c:587` | `EXPORT_SYMBOL_GPL`; the last thing Linux's own `execve` does |
| the virtual system-call page is mapped by the loader | `fs/binfmt_elf.c:1270`, `arch_setup_additional_pages` | so a loader that does not call it never maps the page |
| the legacy page consults seccomp | `arch/x86/entry/vsyscall/vsyscall_64.c:216` | `secure_computing()` runs before the three calls at `:234` onward |
| a raw-frame-number area is copied on fork | `mm/memory.c:1340`, `vma_needs_copy` | returns true for `VM_PFNMAP \| VM_MIXEDMAP` |
| the flag that makes fork correct | `kernel/fork.c:702`, `:745`, `VM_WIPEONFORK` | duplicates the area, copies no page tables |
| a forced signal is unblocked before delivery | `kernel/signal.c:1337` | so blocking a trap converts it to a kill |
| the effective permission rule | `arch/x86/mm/dump_pagetables.c:259` | user and write are the AND across levels, no-execute the OR |
| a per-address-space kernel-half mapping, in-tree | `arch/x86/kernel/ldt.c:236`, `:393` | Linux maps a per-process structure in the kernel half at a fixed index, and frees it per address space |
| `register_die_notifier`, `unregister_die_notifier` | `kernel/notifier.c:604`, `:610` | `EXPORT_SYMBOL_GPL` |
| a stopped notifier cancels the kill | `arch/x86/kernel/dumpstack.c`, `die()` and `oops_end()` | `sig = 0` on a stop, and `oops_end` returns on `!signr` |
| the module region under randomization | `arch/x86/include/asm/page_64_types.h` | the kernel image reserves 1 GiB with randomization and 512 MiB without, so the region is 1008 MiB or 1520 MB |
| Rust and C must agree on the type tag | `init/Kconfig`, `arch/Kconfig` | `RUST` depends on the normalization capability when the checked scheme is on, which the help text says is necessary for using it with Rust |
| the rewrite runs in both directions | `arch/x86/kernel/alternative.c:1215`, `cfi_rewrite_endbr` | the landing marker at a function's entry is poisoned, so calls *down* trap too |
| `migrate_disable`, `set_cpus_allowed_ptr` | `kernel/sched/core.c` | exported; and the affinity refusal for a bound thread is gated on a stricter form the ordinary call does not use, `:3046` |
| the preemption count may not exist | `kernel/Kconfig.preempt:89`, `include/linux/preempt.h:286` | selected only by preemption; without it the disable is a compiler barrier |
| `vhost_task_create` | `kernel/vhost_task.c` | `EXPORT_SYMBOL_GPL`; a thread of a chosen process |
| the virtualization root is taken at load | `virt/kvm/kvm_main.c`, and the emergency callback at `arch/x86/kernel/reboot.c:537` | a single pointer that warns on a second registrant |
| memory slots are user addresses | `virt/kvm/kvm_main.c:2007` | which is why tenant memory as host kernel addresses is not expressible there |
