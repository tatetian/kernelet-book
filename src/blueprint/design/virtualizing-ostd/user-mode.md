# User mode

*Part of question 2. Virtualizes `user` and the fallible half of `mm::io`: the ring transition, system-call and exception return, and page faults taken in kernel mode by user copies. Discharges invariant I5 for the fixup path and invariant I3's backstop: a kernelet's fault ends the kernelet, not the machine.*

The tenant's processes run in ring 3 under the kernelet's own page tables. The instructions that switch rings, the `sysret` and `iretq` on the way out and the `syscall` and trap entries on the way in, belong to the host: the syscall MSRs and the interrupt descriptor table are the host's, and the entry code that lands on the kernel stack is host text. So the round trip into user mode is a service call, and everything around it, the loop, the hooks, the handling of what came back, stays in the kernelet where the kernel proper expects it.

## The round trip

`UserMode::execute` keeps OSTD's loop (checked on the tree: `ostd/src/arch/x86/cpu/context/mod.rs`); only the line that enters ring 3 changes:

```rust
// OSTD (kernelet build), the virtualized `UserContextApiInternal::execute`
fn execute<T: UserModeHooks>(&mut self, hooks: &T) -> ReturnReason {
    self.user_context.general.rflags |= (RFlags::INTERRUPT_FLAG | RFlags::ID).bits() as usize;
    loop {
        crate::task::scheduler::might_preempt();          // reads NEED_RESCHED from the mirror; yields
        let guard = crate::irq::disable_local();          // the aliased guard: preempt_count += 1
        hooks.pre_user_run(&guard);                       // the kernel loads FS base, GS base, FPU into the CPU
        let why = services().user_run(&mut self.user_context as *mut RawUserContext);
        drop(guard);
        match why {
            0 => return ReturnReason::UserSyscall,
            1 => { self.exception = CpuException::new(self.user_context.trap_num, self.user_context.error_code); return ReturnReason::UserException; }
            _ => {}                                       // an interrupt the host handled; loop
        }
        if hooks.has_kernel_event() { return ReturnReason::KernelEvent; }
    }
}
```

The preemption count is raised from `pre_user_run` through `user_run` so that the state the kernel's hook loaded into the CPU, the thread's FS and GS bases and its FPU registers (checked on the tree: `kernel/core/src/process/posix_thread/thread_local.rs`), is still in the CPU when the host performs the transition; the host does not move a task whose count is nonzero ([Tasks](tasks.md)), and `user_run` is not a sleeping call, so the service prologue accepts it under the count. `RawUserContext` is `#[repr(C)]` in `ostd::kernelet::abi`, with the general registers, the instruction and stack pointers, the flags, and the trap number and error code the transition fills in; it is the kernel proper's `UserMode` field, a local of the task's entry closure on the task's own kernel stack (checked on the tree: `kernel/core/src/thread/task.rs`), which the service half's pointer rule admits, and the host reads it before the transition and writes it after.

On the host side, `user_run` does what `UserContext::run` does today: saves the kernel-side callee state, loads the user register file, and returns to ring 3 under its own interrupt guard. Whatever brings the CPU back, a `syscall`, an exception, or an interrupt, lands in the host's entry code on the task's kernel stack, which stores the user registers back into the context and returns from `user_run` with the reason. A system call is then handled by the kernel proper from its own loop, identically. An exception is `take_exception`'d identically. An interrupt has already been handled by the host before `user_run` returns `2`; the host may also have preempted the task there, since a task in user mode is at service-call depth one but holds no host lock, and the loop's `might_preempt` on the next iteration is where the kernelet's own preemption points are honored.

**Killing a task in user mode.** A task in ring 3 is inside `user_run` and will reach the epilogue, where a dying kernelet's task is terminated, only when it comes back. `kill` therefore sends a reschedule interrupt to every host CPU on which a task of the kernelet is running, as the host already does to enforce `need_preempt` remotely; the interrupt returns `user_run` with `2`, and the epilogue terminates the task. The cost is one interrupt per running task per kill.

`UserContextApi`, `UserModeHooks`, `ReturnReason`, `UserContext` and its register types, `CpuException`, `FpuContext` and `FsBase` are identical, as the [taxonomy](index.md) lists; `GsBase` is virtualized to a direct MSR access, since its `swapgs` bracket is safe only with interrupts really disabled.

## Page faults in user copies

The kernel proper reads and writes user memory through `VmReader` and `VmWriter` with `Fallible`, whose copy routines carry exception-table entries: a fault inside one is resolved by the host's page-fault handler, which first asks the kernel's injected user-page-fault handler to map the page (demand paging, copy-on-write) and, if that fails, jumps to the routine's recovery address so that the copy reports how far it got (checked on the tree: `ostd/src/mm/fault/mod.rs`, `handle_user_page_fault`). Inside a kernelet the copy routines are the same code, in `KW_TEXT`, with their entries in the image's own exception table, whose bounds the entry table gives the host. What changes is who resolves the fault, because the host cannot call the kernelet's fault handler: that would enter the kernelet image from the host's fault path.

The host's handler, on a page fault taken in ring 0 with the CPU slot naming a kernelet task at service-call depth zero, does this:

1. If the faulting address is in the user half and the faulting instruction has an entry in the kernelet image's exception table, it writes the fault address and error code into the task's record (`fault_addr`, `fault_code`), sets the instruction pointer to the entry's recovery address, and returns. It validates the recovery address against `KW_TEXT`, which invariant I5 requires.
2. Otherwise the fault is the kernelet's own bug or a stray pointer, at a window address, a host address, or a user address from code that made no provision for faulting: the host kills the kernelet with `KillReason::KernelFault { addr, ip }` and terminates the task there, since depth zero is a quiescent point. The machine continues.

The kernelet's side of the first case is a retry loop in the virtualized fallible copy:

```rust
// OSTD (kernelet build), ostd/src/mm/io/copy.rs under the feature
fn copy_from_user_fallible(dst: *mut u8, src: *const u8, len: usize) -> usize {
    let mut done = 0;
    loop {
        done += unsafe { memcpy_with_fixup(dst.add(done), src.add(done), len - done) };  // identical routine, identical ex_table entry
        if done == len { return len; }
        let rec = current_task_record();
        let exception = CpuException::page_fault(rec.fault_addr.load(Relaxed), rec.fault_code.load(Relaxed));
        match USER_PAGE_FAULT_HANDLER.get().expect("a page fault handler is missing")(&exception) {
            Ok(()) => continue,                              // the kernel mapped the page; resume where the copy stopped
            Err(()) => return done,                          // as today: a partial copy and `Error::PageFault`
        }
    }
}
```

This is the host kernel's behavior with one extra bounce: the host resolves the fault to the recovery address, the kernelet asks its own kernel to map the page, and the copy resumes. The injected handler is the kernel proper's, identical, and it runs on the faulting task, which is what it does on the host kernel too, only one call deeper. `VmReader::read_fallible` and the rest of the fallible API keep their code over this routine; the `Infallible` cursors are untouched, since a kernel-space address that faults is case 2.

**Faults in host code on window addresses.** The service half writes into a kernelet's memory only through its checked pointer arguments, and it does those writes with fallible copies carrying the host's own exception-table entries, so a pointer that passed the range check but points at a page the kernelet unmapped becomes `-INVALID` rather than a host panic. The host's handler treats a fault in host text with a host exception-table entry exactly as today; a fault in host text without one is a host bug and halts the machine, as today.

## What a tenant sees

Nothing. System calls, signals, exceptions, demand paging and copy-on-write behave as on the host kernel. The only observable difference is time: each round trip pays a service prologue and epilogue on top of the transition, and each first-touch fault inside a user copy pays one more return-and-call than on the host kernel.

## Costs

- Per round trip into ring 3: the crossing's prologue and epilogue, *estimated* at 25 cycles, on top of the transition itself; the booted prototype measured a cold page fault at 10,345 cycles in its guest against 9,791 in Asterinas itself (see the Paper's Evaluation section), which bounds what this design should expect for a whole fault.
- Per first-touch fault in a user copy: the host's handler, a task-record write, the recovery jump, the kernelet's handler call, and a resumed copy; one indirect call and two loads more than the host kernel's path.
- Per kill of a kernelet with tasks in user mode: one reschedule interrupt per such task.

## What this page decides

- **The ring transition is a service call and the loop stays in the kernelet** (register D20). The alternative, moving the whole `execute` loop into the host, would make the kernel's `UserModeHooks` closures cross the boundary, against invariant I5, and would put the syscall dispatch path's first instructions on the wrong side of the crossing.
- **Kernel-mode faults in user copies are resolved by fixup and retry, never by calling into the kernelet from the fault path** (register D21). The alternative, the host calling the kernelet's injected handler as it calls its own, breaks the entry rule and would run kernelet code on the host's fault path with the host's state.
- **A kernelet's own kernel-mode fault kills the kernelet** (register D22), not the machine, which is invariant I3's backstop made concrete: a stray pointer in the kernelet build's own code, or in kernelet code at a window address it unmapped, ends one sandbox.
