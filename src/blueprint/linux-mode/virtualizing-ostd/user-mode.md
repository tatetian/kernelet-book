# User mode

*How a tenant's program runs, and how its system calls and exceptions reach its kernelet and nothing else. This is the page the Linux patch exists for. It discharges the first half of safety: the kernelet is the tenant's only kernel.*

## The problem: two kernels that disagree about who calls whom

The kernel proper enters user mode by calling a function. It builds a `UserContext`, the register file of a user thread, and calls `UserMode::execute`. The call returns when something brings the processor back: a system call, an exception, or an event the kernel asked to be told about. The kernel proper handles what came back and calls `execute` again. A tenant thread is therefore a loop in the kernel, *and the loop's local variables live on a kernel stack across every trip to user mode*.

Linux is built the other way around. User mode calls the kernel. A Linux task's kernel stack is empty while the task is in user mode, a system call builds a few frames on it, and returning to user mode discards them. Nothing in Linux can be "in the middle of a function" while its task runs user code.

Three things make this hard for code that Linux loads rather than contains, and each is a fact about Linux rather than about this design:

- **A kernel thread cannot enter user mode.** It has no user register state to return to and no address space of its own.
- **Nothing outside Linux can answer a system call.** Linux lets a call be observed (tracing), vetoed (seccomp) or bounced to user space (ptrace, Syscall User Dispatch), but no interface lets kernel code that Linux did not ship service the call in place.
- **The obvious user-space bounce is not a boundary.** Syscall User Dispatch turns a system call into a signal, which a handler could forward. Linux clears that setting at every `fork` and `exec` ([`dup_task_struct()`](https://elixir.bootlin.com/linux/v6.12/source/kernel/fork.c#L1143)), and [its own documentation](https://docs.kernel.org/admin-guide/syscall-user-dispatch.html) says it "should not be seen as a security mechanism". It also costs at least 885 ns per call where the mechanism below costs nothing measurable (*measured*, see [the prototype](../prototype.md)).

## The answer in one picture

<figure class="fwd-fig">
<div class="head">
<div class="tag">The round trip</div>
<div class="title">One Linux task, two stacks: <code>execute()</code> really returns</div>
</div>
<svg viewBox="0 0 900 380" role="img" aria-label="A tenant thread is one Linux task with two kernel stacks. In user mode the tenant program runs. A system call enters Linux's entry path on the Linux kernel stack, reaches the gate after seccomp, and the gate's syscall hook switches to the kernelet stack, where the kernel proper's call to execute returns with the reason UserSyscall. The kernel proper handles the call and calls execute again; vOSTD's user_run service switches back to the Linux stack, the hook writes the registers into Linux's saved user registers and tells Linux the call was serviced, and Linux returns to user mode. Linux's own system-call table is never reached.">
<defs>
<linearGradient id="um-cg" x1="0" y1="0" x2="1" y2="0">
<stop offset="0%" stop-color="#00F7FF" stop-opacity=".22"/>
<stop offset="100%" stop-color="#1937FF" stop-opacity=".22"/>
</linearGradient>
<marker id="um-a" viewBox="0 0 8 8" refX="7" refY="4" markerWidth="7" markerHeight="7" orient="auto-start-reverse">
<path d="M0 0 L8 4 L0 8 z" fill="#9AA0BE"/>
</marker>
<marker id="um-ac" viewBox="0 0 8 8" refX="7" refY="4" markerWidth="7" markerHeight="7" orient="auto-start-reverse">
<path d="M0 0 L8 4 L0 8 z" fill="#00F7FF"/>
</marker>
</defs>
<g font-family="ui-monospace,monospace" font-size="10.5">
<rect x="20" y="20" width="860" height="46" rx="6" fill="rgba(255,255,255,.06)" stroke="rgba(255,255,255,.16)"/>
<text x="36" y="40" fill="#9A9DB0" font-size="9" letter-spacing="1.4">USER MODE</text>
<text x="450" y="48" fill="#C9CCE0" text-anchor="middle">tenant program &#183; ... mov $1,%rax &#183; syscall &#183; ...</text>
<path d="M20 82 H880" stroke="rgba(255,255,255,.28)" stroke-dasharray="5 4"/>
<text x="878" y="96" fill="#6A6F8C" font-size="8" text-anchor="end">kernel mode &#183; the same Linux task (a carrier)</text>
<rect x="20" y="106" width="400" height="254" rx="10" fill="rgba(255,255,255,.025)" stroke="rgba(255,255,255,.12)"/>
<text x="64" y="124" fill="#9A9DB0" font-size="9" letter-spacing="1.4">LINUX KERNEL STACK &#183; 16 KiB</text>
<rect x="64" y="136" width="340" height="30" rx="5" fill="rgba(255,255,255,.06)" stroke="rgba(255,255,255,.16)"/>
<text x="234" y="155" fill="#9AA0BE" text-anchor="middle">entry code &#183; saved registers (pt_regs)</text>
<rect x="64" y="174" width="340" height="30" rx="5" fill="rgba(255,255,255,.06)" stroke="rgba(255,255,255,.16)"/>
<text x="234" y="193" fill="#9AA0BE" text-anchor="middle">seccomp filter</text>
<rect x="64" y="212" width="340" height="46" rx="5" fill="rgba(25,55,255,.22)" stroke="rgba(0,247,255,.5)"/>
<text x="234" y="231" fill="#00F7FF" text-anchor="middle">the gate: syscall hook</text>
<text x="234" y="247" fill="#5C93A8" text-anchor="middle" font-size="8.5">copy registers &#183; take a seat &#183; switch stacks</text>
<rect x="64" y="270" width="340" height="34" rx="5" fill="rgba(255,255,255,.03)" stroke="rgba(255,255,255,.10)" stroke-dasharray="4 3"/>
<text x="234" y="291" fill="#6A6F8C" text-anchor="middle">Linux's system-call table &#183; never reached</text>
<rect x="64" y="314" width="340" height="30" rx="5" fill="rgba(255,255,255,.06)" stroke="rgba(255,255,255,.16)"/>
<text x="234" y="333" fill="#9AA0BE" text-anchor="middle">exit path &#183; resume hook &#183; return to user</text>
<rect x="480" y="106" width="400" height="254" rx="10" fill="rgba(0,247,255,.04)" stroke="rgba(0,247,255,.42)"/>
<text x="492" y="124" fill="#00F7FF" font-size="9" letter-spacing="1.4">KERNELET STACK &#183; OWNED BY THE KERNELET TASK</text>
<rect x="496" y="136" width="368" height="66" rx="6" fill="url(#um-cg)" stroke="rgba(0,247,255,.55)"/>
<text x="680" y="154" fill="#8FF6FC" text-anchor="middle">kernel proper (safe Rust, unchanged)</text>
<text x="680" y="172" fill="#C9CCE0" text-anchor="middle" font-size="9.5">loop { why = user_mode.execute(..);</text>
<text x="680" y="188" fill="#C9CCE0" text-anchor="middle" font-size="9.5">handle(why, user_mode.context_mut()) }</text>
<rect x="496" y="232" width="368" height="52" rx="6" fill="url(#um-cg)" stroke="rgba(0,247,255,.55)"/>
<text x="680" y="252" fill="#8FF6FC" text-anchor="middle">vOSTD: UserMode::execute</text>
<text x="680" y="270" fill="#5C93A8" text-anchor="middle" font-size="8.5">calls the service user_run(context) and returns its reason</text>
<rect x="496" y="296" width="368" height="48" rx="6" fill="rgba(25,55,255,.22)" stroke="rgba(0,247,255,.5)"/>
<text x="680" y="316" fill="#00F7FF" text-anchor="middle">endovisor: user_run</text>
<text x="680" y="332" fill="#5C93A8" text-anchor="middle" font-size="8.5">give up the seat &#183; switch stacks &#183; resumes here later</text>
<path d="M300 66 V134" stroke="#9AA0BE" stroke-width="1.4" marker-end="url(#um-a)"/>
<text x="308" y="102" fill="#9AA0BE" font-size="9">1 syscall</text>
<path d="M404 235 H470 Q488 235 488 253 V300 Q488 318 494 318" stroke="#00F7FF" stroke-width="1.4" fill="none" marker-end="url(#um-ac)"/>
<text x="428" y="226" fill="#00F7FF" font-size="9">2 switch</text>
<path d="M866 318 H888 V170 H868" stroke="#00F7FF" stroke-width="1.2" fill="none" stroke-dasharray="3 3" marker-end="url(#um-ac)"/>
<text x="856" y="221" fill="#00F7FF" font-size="9" text-anchor="end">3 execute() returns UserSyscall</text>
<path d="M496 336 H452 Q440 336 430 332 L406 330" stroke="#00F7FF" stroke-width="1.4" fill="none" marker-end="url(#um-ac)"/>
<text x="448" y="352" fill="#00F7FF" font-size="9" text-anchor="middle">4 switch back</text>
<path d="M64 329 H42 V68" stroke="#9AA0BE" stroke-width="1.4" fill="none" marker-end="url(#um-a)"/>
<text x="36" y="230" fill="#9AA0BE" font-size="9" text-anchor="middle" transform="rotate(-90 36 230)">5 return</text>
</g>
</svg>
<figcaption>Steps 3 to 4 are the kernel proper handling the call and calling <code>execute</code> again. While the tenant runs in user mode the Linux stack is empty, as Linux requires, and the kernelet stack holds the suspended loop, as the kernel proper requires.</figcaption>
</figure>

The design has three parts, each defined on the page that owns it and summarized here.

- **A tenant thread is a Linux task**, called a **carrier** ([Tasks](tasks.md)). Linux schedules it, enters and leaves user mode for it, and saves its registers. The kernelet does not create user-mode contexts; it borrows Linux's.
- **Kernelet code runs on a stack of its own**, the **kernelet stack**, which belongs to the kernelet task and survives trips to user mode. The carrier switches onto it to run kernelet code and off it to return to user mode. Switching stacks inside one task is ordinary: it is what Linux does to run interrupt handlers, and Linux's scheduler saves only the stack pointer, so a task may even sleep on a stack Linux did not allocate.
- **A gate in Linux's entry path** hands every system call of a carrier to its kernelet *before* Linux looks up its own handler, and runs the kernelet once more on the way back to user mode whenever there is something for it to see. The gate is the patch.

With those three, `UserMode::execute` keeps its contract exactly: it is a call that enters user mode and returns with a reason. The kernel proper cannot tell which host it is on.

## The gate {#gate}

The **gate** is a pair of hooks added to Linux's *generic entry layer*, the architecture-independent code in [`kernel/entry/common.c`](https://elixir.bootlin.com/linux/v6.12/source/kernel/entry/common.c) that every system-call entry and every return to user mode passes through. A task is *attached* to the gate by a pointer in its task structure:

```c
struct kernelet_gate_ops {
        bool (*syscall)(struct pt_regs *regs);  /* true: serviced; Linux must not dispatch it */
        void (*resume)(struct pt_regs *regs);   /* on the way back to user mode, if work is pending */
};
struct kernelet_gate { const struct kernelet_gate_ops *ops; };   /* first field of the endovisor's carrier record */
```

**The syscall hook** is called from [`syscall_trace_enter()`](https://elixir.bootlin.com/linux/v6.12/source/kernel/entry/common.c#L28), directly after seccomp. That function is where Linux already keeps its three ways of intercepting a call, and no entry instruction can reach a Linux system call without passing through it: the 64-bit `syscall`, the legacy `int $0x80`, and both 32-bit fast entries. (The 32-bit fast entries first read one word from the user stack. If that read fails, Linux returns an error to the program without reaching the gate, and without running any system call either; [Memory](memory.md#cache) says how the read is made to fail cleanly.) When the hook returns true the function returns −1, which is Linux's existing convention for "an earlier stage has answered this call; do not dispatch it" ([`do_syscall_64()`](https://elixir.bootlin.com/linux/v6.12/source/arch/x86/entry/common.c#L76) then skips the table). Linux only calls `syscall_trace_enter()` for tasks with a bit set in their *syscall-work* mask ([`SYSCALL_WORK_ENTER`](https://elixir.bootlin.com/linux/v6.12/source/include/linux/entry-common.h#L44)), so the patch adds one bit to that mask, and a task that is not a carrier pays nothing at all.

**The resume hook** is called at the top of [`exit_to_user_mode_loop()`](https://elixir.bootlin.com/linux/v6.12/source/kernel/entry/common.c#L90), the loop Linux runs before returning to user mode whenever a task has pending work: a signal, a reschedule, a notification. It is placed *before* Linux delivers signals, which is what lets the kernelet own its tenant's exceptions ([below](#exceptions)). The loop is off the fast path, so testing the pointer there costs other tasks nothing measurable either.

The hook is called on every pass of that loop for a carrier, including passes that Linux makes only to reschedule, so its first act is to check whether the kernelet has anything pending (a register file to apply, an exception, a tick, a signal to take) and to return at once if not.

**Asking for the resume hook.** Linux enters that loop only if the task has a work flag set. A pending signal sets one. When the endovisor itself wants the hook to run, it sets the flag Linux provides for "call me back before this task returns to user mode", `TIF_NOTIFY_RESUME`: on the current task with a plain flag-set, and on another task with Linux's `set_notify_resume()`, which also interrupts the task's processor if it is running (both are inline or exported). The patch adds no flag of its own. This chapter says the endovisor *flags the carrier* when it means this.

**Attachment is inherited.** [`dup_task_struct()`](https://elixir.bootlin.com/linux/v6.12/source/kernel/fork.c#L1101) copies the whole task structure, including the gate pointer and the syscall-work bit, when a task is created. A carrier's child is therefore attached before it exists, and there is no instant at which it could make a system call that Linux would answer. This is the difference between a field Linux does not know about, which it copies, and a setting Linux knows about, which it resets.

The whole patch is on the [endovisor page](../endovisor.md#patch), with its size as built.

## `user_run`, step by step {#user-run}

vOSTD's `execute` is unchanged from OSTD's except for one line: where OSTD runs its own assembly to switch to user mode, vOSTD calls the service `user_run(context)`, which returns `0` for a system call, `1` for an exception, and `2` for "something happened that the kernel proper may care about; ask it, then call me again". On Linux the endovisor implements it as follows.

**Leaving.** `user_run` records the context pointer in the carrier record, gives up the carrier's [seat](tasks.md#seats), and switches from the kernelet stack to the Linux stack, landing inside whichever hook resumed the kernelet earlier. That hook copies the context into `pt_regs`, the user register file Linux saved on entry, and returns. Linux then returns to user mode by its own exit path, choosing `sysret` or `iret` by its own rules.

Three details make the copy safe. The flags are sanitized: the interrupt flag is forced on and the privilege, nested-task and alignment-check bits are cleared, so a tenant cannot use its kernelet to run with interrupts off. The code and stack selectors are fixed to Linux's 64-bit user segments. And `orig_ax`, Linux's record of "which system call is in progress", is set to −1, which disables Linux's system-call restart logic; restarting is the kernel proper's business, and it does it in its own signal code.

**Coming back by a system call.** The syscall hook copies `pt_regs` into the context. The layout already matches what the hardware did: `rcx` and `r11` hold the return address and flags, as the `syscall` instruction leaves them, and the call number is taken from `orig_ax`. The hook takes a seat, switches to the kernelet stack, and `user_run` returns `0`.

**The first entry.** A new carrier starts in an in-kernel function, not at a system call ([Tasks](tasks.md#carriers)). When its kernelet task first calls `user_run`, the carrier's start function returns, and Linux's fork-return path would zero the `rax` it is about to restore. The endovisor therefore marks the carrier as having pending work, so that the resume hook runs last and applies the full register file.

**Entries that are not 64-bit system calls.** A carrier that executes `int $0x80` or a 32-bit entry instruction still reaches the gate, because every entry does. The kernel proper speaks only the 64-bit ABI, so the hook reports a general-protection exception, which is what the same instruction raises when Asterinas is the host.

## Exceptions {#exceptions}

When a tenant's instruction faults, Linux's exception handlers run first. What they do depends on the exception, and the kernelet needs all of them to arrive as `ReturnReason::UserException` carrying the trap number, the error code and, for a page fault, the faulting address.

**A page fault on a tenant address** is the common case and has its own fast path: Linux calls the fault handler of the carrier's memory area, which belongs to the endovisor. That path is on the [Memory](memory.md#cache) page. When the handler decides the kernel proper must see the fault, it records the address and error code in the carrier record and flags the carrier, and the resume hook delivers it.

**Every other exception** (divide error, invalid opcode, general protection, breakpoint, single step, a fault on a non-canonical or kernel address) ends with Linux *forcing a signal* on the task: it records the trap number, error code and address in the task's thread structure ([`do_error_trap()`](https://elixir.bootlin.com/linux/v6.12/source/arch/x86/kernel/traps.c#L209), [`set_signal_archinfo()`](https://elixir.bootlin.com/linux/v6.12/source/arch/x86/mm/fault.c#L630)), queues `SIGSEGV`, `SIGILL`, `SIGFPE`, `SIGBUS` or `SIGTRAP`, and heads for user mode, where it would normally deliver the signal or kill the task.

The resume hook runs before that delivery. It takes every pending signal except `SIGKILL` off the carrier's queue with [`dequeue_signal()`](https://elixir.bootlin.com/linux/v6.12/source/kernel/signal.c#L626), which is exported, holding the task's signal lock as that function requires. A signal that Linux itself raised for a fault, which its signal record distinguishes from one that a process sent, becomes `user_run` returning `1`, with the three values read back from the thread structure. Any other signal can only have come from the host side (a tenant cannot send Linux signals, because it cannot make Linux system calls); it is discarded, and `user_run` returns `2`. `SIGKILL` is left alone: it is how the operator and the endovisor end a carrier, and Linux acts on it in the same loop. Before it resumes the kernelet with an exception, the hook copies Linux's saved user registers into the context, as the syscall hook does; the context would otherwise still hold the registers of the previous trip. *Measured on the booted prototype*: an illegal instruction in a tenant program reached the kernel proper this way, as trap 6 with the right instruction pointer ([the prototype](../prototype.md#probe)).

One side effect has to be switched off. When Linux forces a signal that the task does not handle, it prints a line such as `traps: ... invalid opcode` or `segfault at ...` in the *host's* log, rate-limited; the prototype's log shows one for the probe kernel's illegal instruction. A tenant must not be able to write to the operator's log, even at a limited rate. Linux prints only for signals whose disposition is the default, so the root carrier, after its `exec`, gives the fault signals a disposition that is neither default nor ignore, which every carrier inherits. The handler it names is never run, because the resume hook always takes the signal first. **[unverified]**: read from Linux's `show_signal()`; not tried. One path remains: misuse of the legacy vsyscall page (a misaligned call, a bad stack pointer) makes Linux print a warning whatever the disposition. Linux rate-limits it, and an operator who wants none of it turns the host's `debug.exception-trace` setting off, which silences this whole class of message.

Two alternatives were tried on paper and fail. *Blocking* the signals does not work: [`force_sig_info_to_task()`](https://elixir.bootlin.com/linux/v6.12/source/kernel/signal.c#L1325) unblocks a forced signal and resets its handler to the default, so blocking turns a trap into a kill. *Catching* them with a handler inside the tenant makes Linux write a signal frame onto the tenant's stack, which may not be writable, and puts a trusted trampoline into an address space the tenant controls.

## Kernel events: the user-mode tick {#tick}

The kernel proper sometimes needs a thread that is in user mode to come back: to deliver a POSIX signal another thread sent it, or to stop it. OSTD has no call for that. It models the need with a hook, `has_kernel_event`, that `execute` consults every time the processor returns from user mode for any reason, and on a machine the periodic timer interrupt guarantees such a return within one tick. A thread spinning in user mode therefore notices a pending signal within a tick, and the kernel proper is written to that expectation.

On Linux a timer interrupt in a carrier is Linux's business and never reaches the kernelet. The endovisor restores the expectation with a **user-mode tick**: while any carrier of a kernelet is in user mode, one Linux timer for that kernelet fires at the kernel proper's tick rate and [flags](#gate) each carrier that is in user mode. The carrier enters the exit loop, the resume hook finds the tick pending and nothing else, `user_run` returns `2`, and `execute` asks `has_kernel_event`, exactly as after a timer interrupt on a machine. The timer is not armed when no carrier is in user mode.

## What the tenant can never reach

- **Linux's system calls**, by any entry instruction, from any thread or child: the gate is in the one function they all pass through, and attachment is inherited.
- **The vDSO**, the page of user-mode code Linux maps into each process so that clock reads avoid a system call. It is mapped by Linux's ELF loader ([`arch_setup_additional_pages()`](https://elixir.bootlin.com/linux/v6.12/source/arch/x86/entry/vdso/vma.c#L317)), and a carrier's address space is never built by that loader ([Tasks](tasks.md#root)), so the page is simply absent. The kernel proper supplies its own, from its own clock.
- **The legacy vsyscall page**, a fixed kernel address that old binaries call for three time-related functions. Linux emulates it inside the page-fault handler, *not* through the system-call path, so the gate never sees it. The emulation reads the caller's return address from the tenant's stack, which is a kernel-mode access that the [fault handler](memory.md#cache) fails cleanly if the page is not there, and then consults seccomp *before it invokes any of the three system calls* ([`vsyscall_64.c`](https://elixir.bootlin.com/linux/v6.12/source/arch/x86/entry/vsyscall/vsyscall_64.c#L216)). A seccomp filter can see the instruction pointer ([`struct seccomp_data`](https://elixir.bootlin.com/linux/v6.12/source/include/uapi/linux/seccomp.h#L62)), which on that path is the page's own address. The [kernelet runtime](../kernelet-runtime.md) installs a six-instruction filter that answers *trap* for that address and *allow* for everything else, and every carrier inherits it. *Trap* makes Linux skip the emulated call and force a `SIGSYS`, which the resume hook takes like any other forced signal and reports to the kernel proper as a page fault: trap 14, an error code that says *user mode, instruction fetch, page not present*, and the address of the call, which Linux records in the signal. The hook also undoes the one thing the emulation did, which was to pop the return address, so that the saved registers are those of the faulting `call`. That is what calling the page does when Asterinas is the host, where nothing is mapped there. **[unverified]**: read from the source; the prototype's kernel was built without the legacy page. An operator who boots Linux with `vsyscall=none` does not depend on the filter.

What a *privileged host user* can do to a carrier is a different matter, and nothing here prevents it: Linux's tracing stage runs before the gate, so a host debugger attached to a carrier can observe and suppress its system calls, exactly as root on the host can read any container's memory. The [runtime](../kernelet-runtime.md) closes the unprivileged version of this by giving each sandbox its own user identity and by making the sandbox file execute-only, which leaves the carriers not *dumpable*.

## Thread pointer and floating-point state

`UserContext` carries the FS base, which user programs use for thread-local storage. Linux caches it per task and restores it on every context switch, so writing the register alone would be undone. The endovisor writes both the task's saved field and the register, with preemption off between the two, before leaving for user mode.

Floating-point and vector registers are simpler than on the Asterinas host, because a carrier never runs a different tenant thread: they are the Linux task's own state and Linux saves and restores them. Kernelet code is compiled without them, so a round trip leaves them untouched in the processor. The kernel proper reads or writes them only to build or restore a signal frame and to initialize a new thread. For that, the endovisor copies between the kernelet's buffer and either the live registers or Linux's saved copy, whichever Linux's own flag says is current, inside Linux's `fpregs_lock()` bracket. **[unverified]**: read from the source, not built.

## Costs

- **Per system call**: the hook's two register-file copies (about 170 bytes each way), two stack switches, and an uncontended seat acquire and release. Against that, Linux's own dispatch is skipped. *Measured* in an earlier experiment, a per-task hook that returned a constant cost 39 ns per call against 44 ns for a call Linux services itself, in the same guest: reaching a kernelet costs about what reaching Linux's own handler costs ([the prototype](../prototype.md)). The stack switch and the seat were not in that measurement.
- **Per non-page-fault exception**: Linux's signal queueing and the dequeue, a few hundred nanoseconds (*estimated*), on a path that is rare and already slow.
- **Per user-mode tick**: one timer interrupt per kernelet, and for each carrier in user mode a flag, a pass through the exit loop and one round trip into the kernelet that finds nothing to do, about a microsecond (*estimated*), at the kernel proper's tick rate. A machine pays a timer interrupt per tick per processor for the same purpose.

## What a tenant sees

System calls, signals, demand paging and exceptions behave as they do when Asterinas is the host. Two differences are observable. A program that executes a 32-bit system-call instruction gets `SIGSEGV`, as on Asterinas, where under Linux proper it would have got a system call; in one corner it gets something Asterinas would not give it, an error return of `-EFAULT` that its own kernel never saw, when it uses a 32-bit fast entry with a stack pointer that points at nothing. And the time a physical interrupt takes while a carrier is in user mode is charged to the sandbox, as it is to any Linux process.

## What this page decides

- **The tenant's threads are Linux tasks, and `user_run` is a real call that enters user mode and returns** (register D90). The kernelet task's frames wait on a kernelet stack while Linux's stack empties, so neither kernel's assumption is broken. The alternative, servicing calls on a separate kernel thread and parking the tenant's task, was rejected because address-space work must run on the task whose address space it is, and because a handoff costs microseconds per call.
- **The gate is two hooks in the generic entry layer, keyed by an inherited per-task pointer** (register D91): one after seccomp on the way in, one before signal delivery on the way out. The alternative, a hook in one architecture's entry code, covered one of x86-64's four entry instructions.
- **A thread in user mode is brought back for kernel events by a user-mode tick** (register D114), which reproduces what a machine's timer interrupt does for OSTD. The alternative, a "kick" service, has no caller: OSTD's interface has no such call for the kernel proper to make.
- **Exceptions are taken from Linux's signal queue by the resume hook** (register D92), not blocked and not caught in the tenant. It costs the second hook and asks Linux for nothing else.
