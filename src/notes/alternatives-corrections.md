# What the alternatives exploration corrected

*Every place the exploration found the book wrong, with the citation that settles it. Twenty-one of them. They are collected here because [Alternative designs](../blueprint/alternatives/index.md) opens by claiming the chapter it attacks was wrong, and a claim of that shape has to be checkable rather than counted. Most are already applied; where one is not, the entry says so.*

All of these are applied except the last, which is flagged in the register and left for the pass that resolves it.

1. **D82's proposed sequence protocol has a sleeping point, and the chapter presents it
   as the answer.** `mmu_interval_read_begin()` ends in `wait_event(subscriptions->wq,
   ...)` at `mm/mmu_notifier.c:249` when an invalidation is in flight. So read-begin can
   block. That is fine on a system-call path that may sleep, and it is *not* fine on the
   futex path, which Linux runs with page faults disabled, and not inside the
   non-sleeping lock the chapter itself says the map must take. The chapter currently
   says "read-begin before the lookup and read-retry before the commit, all of which is
   exported" without saying that the first of them can sleep.

2. **A21's two costs are one cost.** The chapter lists the pinning refusal and the
   absent teardown callback as separate consequences of inserting raw frame numbers.
   They are bought with the same flag: `zap_vma_ptes()` at `mm/memory.c:1955` silently
   returns unless the area carries `VM_PFNMAP`, which is the same flag that makes the
   pages unpinnable. So the design cannot take the good half without the bad half, and
   the chapter should say that it is a single trade.

3. **The hardware rule that makes the whole SMAP problem softer than the chapter says.**
   `effective_prot()` at `arch/x86/mm/dump_pagetables.c:259` states it: effective
   `_PAGE_USER` and `_PAGE_RW` are the **AND** across paging levels, effective `_PAGE_NX`
   is the **OR**. So the same leaf tables reached through a top-level entry with
   `_PAGE_USER` cleared are supervisor-only, and the supervisor-access check has nothing
   to refuse. The chapter treats the check as an absolute prohibition on reaching a
   tenant's address; it is a prohibition on reaching it *through a user mapping*.

## The system-call path and the tenant's processes

4. **"Three more hook sites" is an enumeration where one would do.** Every x86 entry —
   `do_syscall_64`, `do_int80_emulation`, the FRED variants, `do_int80_syscall_32`,
   `__do_fast_syscall_32`, and the two that tail-call it — funnels through
   `syscall_enter_from_user_mode[_work]`, and both reduce to `syscall_trace_enter()` at
   `kernel/entry/common.c:28`, which is where dispatch, ptrace and seccomp already live
   and where the `return -1L` convention the patch tests comes from. One hook there
   covers every entry by construction, and generic entry is selected by x86, s390, riscv
   and loongarch, so the hook stops being architecture-specific. `syscall_work` has 57
   free bits.

5. **The legacy virtual system-call page does consult seccomp, and D83 can be
   withdrawn.** `emulate_vsyscall()` calls `secure_computing()` at
   `arch/x86/entry/vsyscall/vsyscall_64.c:216`, before invoking the three calls at `:234`
   onward. Seccomp's filter input carries `instruction_pointer` (`kernel/seccomp.c:265`),
   which on this path is the vsyscall address. So a short seccomp filter closes that
   escape per sandbox, with no patch and no boot option. The chapter says the path is
   below seccomp, and requires `vsyscall=none` of the operator. Both are wrong.

6. **The hook's inheritance is the mechanism, not a defect.** `copy_process` copies the
   whole task structure with `memcpy` (`arch/x86/kernel/process.c:95`, via
   `arch_dup_task_struct` at `kernel/fork.c:1112`), so the child carries the kernelet
   fields before it exists. It is not runnable until `wake_up_new_task` at
   `kernel/fork.c:2817`, and it leaves through `ret_from_fork` and
   `syscall_exit_to_user_mode`, which is the exit path, so it never passes the entry hook
   on its way out. There is no window in which a child runs unattached. The chapter
   records this as a lifetime defect.

7. **Nothing clears a field Linux does not know about.** Syscall User Dispatch dies at
   fork and exec because two explicit lines clear it (`kernel/fork.c:1143`,
   `fs/exec.c:1310`). That is a fact about dispatch, not about interception, and the
   chapter generalizes it further than it goes.

8. **Linux does notify a mapping's owner, at area granularity.** `dup_mmap` calls
   `vm_ops->open` on the child's new area (`kernel/fork.c:726`), and `remove_vma` calls
   `vm_ops->close` (`mm/vma.c:326`). A21 says nothing calls back on teardown; that is
   true per page and false per area.

9. **A latent data leak in the design as it stands.** A `VM_PFNMAP` area *does* have its
   page tables copied into a forked child: `vma_needs_copy` returns true for
   `VM_PFNMAP|VM_MIXEDMAP` (`mm/memory.c:1340`). So a tenant that forks would share the
   parent's frames with the child, writably, with no copy-on-write. `VM_WIPEONFORK`
   (`kernel/fork.c:702` and `:745`) is exactly "duplicate the area, copy no page tables"
   and is the flag that makes fork correct. Nothing in the chapter mentions either.

10. **The modern virtual system-call page closes itself.** It is mapped by
    `arch_setup_additional_pages()`, called from `fs/binfmt_elf.c:1270`. A kernelet that
    loads its tenant's programs itself simply does not call it, and the page is never
    mapped. The chapter says the endovisor must unmap or replace it.

11. **A third entry into the kernelet, which no page counts.** A tenant enters by a
    system call, by a *fault* (the area's fault handler, which the design already uses),
    and by Linux **delivering a signal** on the tenant's task:
    `arch_do_signal_or_restart` in `exit_to_user_mode_loop`
    (`kernel/entry/common.c:110`) writes a signal frame onto the tenant's user stack and
    moves its instruction pointer, behind the kernelet's back. This is a new limitation,
    not a correction, and it is the one nobody has closed.

## The execution environment

12. **The cpuset limitation is not Linux's.** The chapter says a thread bound at creation
    carries `PF_NO_SETAFFINITY` and so cannot join a cpuset. The rejection is gated on
    `SCA_CHECK` (`kernel/sched/core.c:3046`), and `set_cpus_allowed_ptr()` passes
    `.flags = 0`, so `kthread_create()` followed by `set_cpus_allowed_ptr()` yields a
    pinned thread that *is* cpuset-attachable. Linux's own virtual-machine worker does
    the equivalent. The row should be withdrawn.

13. **The per-CPU repair the chapter names is a no-op on the kernel its own experiments
    ran on.** `CONFIG_PREEMPT_COUNT` is selected only by `PREEMPTION`
    (`kernel/Kconfig.preempt:89`), the test guest is `CONFIG_PREEMPT_NONE=y`, and on such
    a kernel `preempt_disable()` is `barrier()` (`include/linux/preempt.h:286`) and
    `preemptible()` is the literal `0`. So "`disable_preempt` must become an actual host
    preemption disable, which any module may use" is not available on every host, and a
    module cannot even ask which preemption model it is on unless the kernel is built
    dynamic.

14. **A20 understates the stack hazard.** A guard-page overflow on a stack Linux does not
    know about is not diagnosed as a stack overflow at all; it ends in
    `panic("Machine halted.")`. The assumption says backtraces stop at the switch, which
    is the smaller half.

## Loading and the hardware

15. **The metadata region's "fourth export" is two.** `apply_to_page_range` is exported
    (`mm/memory.c:2988`) but takes a `struct mm_struct *`, and the one it must be given,
    `init_mm`, is not exported at all.

16. **A19 names only one of the two directions.** Under the type-checked scheme
    `cfi_rewrite_endbr()` poisons the landing marker at a function's entry
    (`arch/x86/kernel/alternative.c:1215`), so a kernelet's calls *down* into host service
    functions trap as well as the host's calls *up* into the entry table.

17. **But A19's hardest half is already a Linux requirement.** `init/Kconfig:1953` makes
    `RUST` depend on `!CFI_CLANG || HAVE_CFI_ICALL_NORMALIZE_INTEGERS_RUSTC` and select
    integer normalization, and `arch/Kconfig:852` says in as many words that the option
    "is necessary for using CFI with Rust". So Linux 6.12 already requires its Rust and C
    compilers to compute the same type tag for the same prototype, which is exactly what
    A19 doubts. The assumption should be narrowed to what remains.

## A methodological note, and the one error it caused

The kernel tree in the scratchpad is **patched**: it carries chapter 13's own two changes.
One wave-one agent read `EXPORT_SYMBOL_GPL(set_memory_rox)` out of it and reported that
the chapter's mandatory export is already upstream. It is not. Extracting
`arch/x86/mm/pat/set_memory.c` from the pristine tarball shows no such line, and the
tree's own `include/linux/sched.h` and `arch/x86/Kconfig` carry `CONFIG_KERNELET_HOOK`.
Pristine copies of the five patched files are now in `scratchpad/linux/pristine/`, and the
tree root carries a warning. Also note that the tree's `Module.symvers` is filtered by a
`tinyconfig` build, so a symbol's absence from it means nothing.

## The largest of them

18. **A kernel-mode fault in code a module owns is recoverable, with no patch.** The
    chapter says fault containment has no answer and that no patch is proposed because
    the containment wanted would mean unwinding whatever the faulting task held. The
    premise is wrong at the first step: the fault does not have to be fatal.

        arch/x86/kernel/dumpstack.c   void die(...)   { int sig = SIGSEGV;
                                        if (__die(str, regs, err)) sig = 0;
                                        oops_end(flags, regs, sig); }
        __die_body()  → notify_die(DIE_OOPS, ...) == NOTIFY_STOP → return 1
        oops_end()    → if (!signr) return;
        kernel/notifier.c:604  EXPORT_SYMBOL_GPL(register_die_notifier)

    So a module-registered die notifier that recognizes the faulting address as a
    kernelet's, rewrites `regs->ip` and `regs->sp` to a landing pad of its own, and
    answers with a stop, resumes execution there instead of killing the task. The
    unwinding objection is answered by the kernelet image itself, which carries the
    kernel proper's unwinder and its `catch_unwind` machinery.

    It is not free and the chapter is right that it is not clean: the oops has already
    been printed by the time the notifier runs, and `console_verbose()` raises the
    console level without restoring it, so a tenant that faults repeatedly can flood the
    machine's console. That makes the argument for a patch here one about fairness rather
    than about function, which is a much better argument than the one the chapter makes.

## Two to the Design chapter

19. **The module region is 1008 MiB on a randomized kernel, not 1520 MB.** The region is
    what is left after the kernel image, and the image reserves 1 GiB when address
    randomization is on and 512 MiB when it is off (`arch/x86/include/asm/page_64_types.h`).
    Distribution kernels randomize. The chapter's figure is the unrandomized case.

20. **The framework's own exception table holds absolute addresses, so the Design
    chapter's region table is wrong.** `ExTableItem` is two `Vaddr` fields
    (`ostd/src/mm/fault/ex_table.rs`) and the four fallible-copy stubs emit them with
    `.quad` (`ostd/src/arch/x86/mm/*_fallible.S`), eight relocations in all. The region
    table lists `.ex_table` under "everything that holds no address" in the shared
    region, and the build audit would reject the image for it. Re-encoding the entries as
    self-relative offsets, which is how Linux encodes its own, makes the section
    shareable, fixes the contradiction on both hosts, and is the precondition for letting
    Linux's fixup search find a kernelet's table. Fixed in chapter 12.

## One to the Overview, still open

21. **Two figures for the same thing, and they disagree.** [Goals](../blueprint/overview/goals.md)
    says a KVM exit and entry cost 5,155 cycles "on the machine that produced this book's
    only measurements". The guest-ring-0 design measured an exit and resume with an
    in-kernel handler on that same machine at 3,002 cycles, with four different exit
    causes within three percent of each other, and confirmed the machine by measuring its
    bare system call at 464 ns against the 485 ns the evidence page records. The two are
    probably not measuring the same path — 5,155 may include a user-space round trip —
    but the book states one of them as a flat fact. A15's lower half is now measured
    rather than scaled from a 2013 paper, and the register says so; the goals figure
    needs the same treatment and is left for the pass that resolves it.
