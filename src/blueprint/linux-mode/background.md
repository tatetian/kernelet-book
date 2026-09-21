# Background: the Linux this chapter needs

*Every Linux concept the design uses, defined once, for a reader who has never worked on the Linux kernel. Each entry says what the thing is, and why this chapter cares. Source references are to Linux v6.12, the version the prototype runs on.*

## Tasks and their two stacks of state

Linux's unit of execution is the **task** ([`struct task_struct`](https://elixir.bootlin.com/linux/v6.12/source/include/linux/sched.h#L778)). A thread is a task; a single-threaded process is a task; a **kernel thread** is a task that has no user address space and never leaves kernel mode.

Every task has a small **kernel stack**, 16 KiB on x86-64, used whenever the task executes in kernel mode. When a task enters the kernel from user mode (by a system call, an exception or an interrupt), the entry code saves the task's user registers at the top of that stack in a structure called **`pt_regs`**. Returning to user mode restores the registers from `pt_regs` and leaves the kernel stack empty. *Why it matters:* to decide what a task will do when it returns to user mode, write its `pt_regs`.

New tasks are made by one function, [`kernel_clone()`](https://elixir.bootlin.com/linux/v6.12/source/kernel/fork.c#L2745), which underlies `fork`, `clone` and kernel-thread creation. It copies the parent's whole task structure ([`dup_task_struct()`](https://elixir.bootlin.com/linux/v6.12/source/kernel/fork.c#L1101)) and then, depending on flags, shares or copies the address space, files, signal handlers and so on. *Why it matters:* anything stored in the task structure is inherited by a child automatically, before the child has run an instruction.

## The entry path, and who may intercept a system call

On x86-64 a program enters the kernel with the `syscall` instruction; legacy 32-bit programs use `int $0x80` or two other instructions. All of them converge, after a few lines of assembly, on architecture-independent C code called the **generic entry layer** ([`kernel/entry/common.c`](https://elixir.bootlin.com/linux/v6.12/source/kernel/entry/common.c)).

On the way **in**, if the task has any bit set in its **syscall-work** mask, the layer calls [`syscall_trace_enter()`](https://elixir.bootlin.com/linux/v6.12/source/kernel/entry/common.c#L28), which runs Linux's three interception mechanisms in order: *Syscall User Dispatch* (turn the call into a signal to the calling process), *ptrace* (let a debugger see it), and *seccomp* (run a small filter program that may allow, deny or kill). Any of them can declare the call answered, in which case Linux skips its own handler. Then Linux looks the call number up in its table and runs the handler.

On the way **out**, if the task has pending work (a signal, a request to reschedule), the layer runs [`exit_to_user_mode_loop()`](https://elixir.bootlin.com/linux/v6.12/source/kernel/entry/common.c#L90) until none is left, and only then restores `pt_regs`.

*Why it matters:* all three interception mechanisms are controlled from user space, and none lets code inside the kernel *answer* a call. The design adds a fourth stage that does.

## Signals

A **signal** is an asynchronous notification to a task. Linux queues it, and acts on it only when the task is about to return to user mode, in the exit loop: it either kills the task or arranges for a handler in the program to run. `SIGKILL` cannot be caught or blocked. When a program's instruction faults (a divide by zero, an illegal instruction), Linux **forces** the corresponding signal with [`force_sig()`](https://elixir.bootlin.com/linux/v6.12/source/kernel/signal.c#L1666), after recording the trap number, error code and address in the task's thread structure.

*Why it matters, twice:* a tenant's exceptions reach this design as forced signals; and a task that stays in kernel mode is never killed by a signal, however long it stays.

## Address spaces, areas, and page faults

A process's user memory is described by an **address space** (`struct mm_struct`), which is a set of **virtual memory areas** (VMAs): contiguous ranges with uniform permissions, each optionally backed by a file. Linux fills page tables lazily. Touching an address with no translation raises a page fault; Linux finds the VMA and asks *it* for the page, by calling the `fault` function of the VMA's operations table ([`struct vm_operations_struct`](https://elixir.bootlin.com/linux/v6.12/source/include/linux/mm.h#L598)). A driver that implements `mmap` on its device file supplies that function, and so decides which physical page appears at each address.

A VMA can be marked as holding **raw frame numbers** (`VM_PFNMAP`). Linux then maps exactly the frames it is told to, with [`vmf_insert_pfn_prot()`](https://elixir.bootlin.com/linux/v6.12/source/mm/memory.c#L2403), and takes no further interest in them: no reference counting, no swapping, no migration, and no pinning on behalf of other subsystems. The driver can remove translations again with [`zap_vma_ptes()`](https://elixir.bootlin.com/linux/v6.12/source/mm/memory.c#L1952).

*Why it matters:* this is how a module can own what a process sees in its memory without owning the process.

## The kernel's own address space

The upper half of every address space belongs to the kernel and is the same in every process. Two regions of it matter here. The **direct map** is all of physical memory, mapped once, in order, with large pages; turning a physical address into a kernel pointer is one addition. The **vmalloc area** is where the kernel builds virtually contiguous ranges out of scattered pages, with [`vmalloc()`](https://elixir.bootlin.com/linux/v6.12/source/mm/vmalloc.c#L3924) or, from pages the caller supplies, [`vmap()`](https://elixir.bootlin.com/linux/v6.12/source/mm/vmalloc.c#L3413); ranges there are separated by unmapped guard pages.

**SMAP.** x86-64 processors since about 2014 refuse a kernel-mode access to a *user* page unless a processor flag is set, and Linux enables the protection. Linux's own routines for copying to and from user memory set the flag for the duration of the copy ([`stac()`](https://elixir.bootlin.com/linux/v6.12/source/arch/x86/include/asm/smap.h#L36)), and recover from bad addresses through an **exception table** that lists the instructions allowed to fault and where to resume. *Why it matters:* kernel code that Linux did not build has no entry in that table.

## Modules and exported symbols

A **module** is kernel code loaded at run time. It may call only those kernel functions that the kernel's source marks as **exported** (`EXPORT_SYMBOL`). Much of the kernel is exported because drivers need it; some of it, deliberately, is not. *Why it matters:* the design's requests of Linux are a list of four functions that are not exported today.

Executable kernel memory is one such case. `vmap()` always produces non-executable memory, and the functions that change a range's permissions ([`set_memory_rox()`](https://elixir.bootlin.com/linux/v6.12/source/arch/x86/mm/pat/set_memory.c#L2118) and its siblings) are not exported.

## Program loaders

When a process calls `execve`, Linux offers the file to each registered **binary-format handler** ([`struct linux_binfmt`](https://elixir.bootlin.com/linux/v6.12/source/include/linux/binfmts.h#L82)) in turn: one for ELF programs, one for scripts, and any that modules have registered with [`__register_binfmt()`](https://elixir.bootlin.com/linux/v6.12/source/fs/exec.c#L88). The handler that recognizes the file replaces the process's address space ([`begin_new_exec()`](https://elixir.bootlin.com/linux/v6.12/source/fs/exec.c#L1222)) and sets the registers the process will start with. Anything else the new program finds in its address space, including the **vDSO** (a page of kernel-supplied code for fast clock reads), is there because the ELF handler in particular put it there.

## Sleeping, waking, thread groups, and descriptors

A task that must wait puts itself on a **wait queue** and sleeps; another context wakes it with `wake_up_process()`. A sleep can be *killable*, meaning a fatal signal ends it, and *freezable*, meaning Linux may park the task in place when the machine suspends. (Freezing a *control group* is a different mechanism: it stops each task as the task passes through Linux's signal-delivery code on its way to user mode.)

Tasks created with the thread flag form a **thread group**, which is what Linux calls a process: they share signal handling, and a fatal signal to one ends them all. Tasks created without it are separate processes even if they are related. Linux also has a helper, [`vhost_task_create()`](https://elixir.bootlin.com/linux/v6.12/source/kernel/vhost_task.c#L118), that gives a module a worker which runs only kernel code yet is a thread of the calling process, and so belongs to that process's control group.

Every process has a **descriptor table** of open files. A child made without the share-files flag gets a copy of its parent's table. When a task exits, for any reason, Linux closes its descriptors, and a file's `release` function runs when its last reference goes.

A module can ask to be called back on a task's way to user mode by setting the task's `TIF_NOTIFY_RESUME` flag, directly for the current task or with `set_notify_resume()` for another, which also prods the processor that task is running on.

When a driver has mapped a file of its own into processes and wants some of those translations gone, it calls [`unmap_mapping_range()`](https://elixir.bootlin.com/linux/v6.12/source/mm/memory.c#L3858): Linux keeps, per file, the list of areas that map it, and removes the range from every one.

## Control groups

A **control group** (cgroup) is a set of tasks with shared resource limits: processor time, memory, and more. Membership is inherited by children. Linux charges processor time to the group of the task that runs, and memory to the group of the task that allocates, including kernel memory when the allocation carries the flag [`__GFP_ACCOUNT`](https://elixir.bootlin.com/linux/v6.12/source/include/linux/gfp_types.h#L153). Writing to a group's `cgroup.kill` file kills every member.

## When the kernel itself faults

A fault in kernel mode with no exception-table entry is an **oops**. Linux prints a report, then calls a chain of **die notifiers**, and then kills the current task. A notifier can call the kill off ([`__die_body()`](https://elixir.bootlin.com/linux/v6.12/source/arch/x86/kernel/dumpstack.c#L424)), and a module can register one ([`register_die_notifier()`](https://elixir.bootlin.com/linux/v6.12/source/kernel/notifier.c#L600)). Operators may configure Linux to panic, and optionally to boot a crash-dump kernel, on any oops.

## Preemption models

A Linux kernel is built, or on recent kernels booted, with one of three **preemption models**. *Full*: a task running kernel code can be rescheduled at almost any instruction, on return from an interrupt. *Voluntary* and *none*, common on servers: a task in kernel mode keeps its processor until it sleeps, returns to user mode, or reaches one of the many places where Linux's own code calls `cond_resched()`, the **voluntary preemption point**, which reschedules if Linux has marked the task as due. *Why it matters:* code that Linux did not write contains no such calls.

## Timers and cross-processor work

An [`hrtimer`](https://elixir.bootlin.com/linux/v6.12/source/kernel/time/hrtimer.c) is a high-resolution timer whose callback runs in interrupt context on the processor that armed it; it never follows a task to another processor. (On a real-time kernel most timer callbacks are moved into threads; a timer created in the *hard* mode still runs in the interrupt itself.) To make another processor do something, such as arm a timer of its own, kernel code sends it a cross-processor call with `smp_call_function_single()`. The timer interrupt records the registers of whatever it interrupted, and a callback can read them with `get_irq_regs()`; Linux's profiler samples programs this way.
