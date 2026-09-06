# Faults, termination, and reclamation

*Cuts across the resources. Specifies what ends a kernelet, how each of its tasks is stopped, and how everything it held is returned. Discharges invariant I7 (termination) in full and the destroy half of I4 (no retained reference).*

A kernelet dies in one of three ways: its kernel asks to (`exit`), its kernel fails (`panic`), or the host decides (`kill`). Whichever it is, the same thing then happens: the kernelet is marked dying, every one of its tasks is stopped at a point where it holds nothing of the host's, and the endovisor is told; when the last task has stopped the kernelet has exited, and `destroy` gives back its memory and every host object that named it. No code from the kernelet image runs on any of those paths after the mark, and no destructor of the kernelet's ever runs on the host's behalf.

## Three tiers

**Tier 1: the kernelet handles it.** A panic on one of the kernelet's threads unwinds to the catch the kernel proper wraps around every user task, the thread dies, and the kernelet continues; that is the kernel proper's own oops mechanism, identical inside a kernelet (checked on the tree: `kernel/core/src/thread/oops.rs`). The only addition is that the wrapped panic handler reports the oops to the host with the `oops` service call, so that the endovisor's budget counts it ([The rest](virtualizing-ostd/the-rest.md)). A memory-allocation failure a fallible path can absorb, `ENOMEM` to a process, is tier 1 too ([Memory](virtualizing-ostd/memory.md)). Nothing on this tier involves the host beyond a counter.

**Tier 2: the kernelet ends.** Everything that ends the kernelet as a whole:

| cause | who detects it | how it reaches the host | `ExitReason` |
|---|---|---|---|
| the kernel calls `power::poweroff`, `restart` or `exit_with_code` | the kernelet | the `exit` service call | `Exited(code)` |
| a panic the oops handler cannot recover, or an allocation failure no fallible path absorbs | the kernelet | the `panic` service call | `Panicked(message)` |
| the endovisor asks | the endovisor | `Kernelet::kill(Requested)` or `HostPolicy(n)` | `Killed(…)` |
| the oops budget is exhausted | the `oops` service call | the host marks the kernelet dying inside the call | `Killed(OopsBudget)` |
| a task holds preemption off for `policy.preempt_off_ticks` ticks | the host tick | the tick's kernel-mode preemption point | `Killed(PreemptOffTooLong)` |
| a service call finds the stack below the reserve | the service prologue | inside the call | `Killed(StackReserve)` |
| a stack overflow in kernelet code | the double-fault handler on its own stack (assumption A6) | the handler | `Killed(StackOverflow)` |
| a page fault in kernelet code with no exception-table entry | the host's page-fault handler | the handler | `Killed(KernelFault { addr, ip })` |

**Tier 3: the host fails.** A panic in host code, in OSTD or in the endovisor, halts the machine as it does today. A kernelet cannot cause one except through a bug in host code, which is the trusted base's to fix; the service half's pointer checks, the device models' descriptor checks and the fallible copies on window addresses are what keep a kernelet's inputs from reaching a host panic ([User mode](virtualizing-ostd/user-mode.md)).

## Marking

Every tier-2 cause converges on one host function, `Kernelet::mark_dying(reason)`, which does, once, under a compare-and-swap from `Running` to `Dying`:

1. Records the reason and the time.
2. Stores `dying` on the info page, so that every service call from now on fails with `-DYING` at its prologue, except the calls that end tasks.
3. For every task of the kernelet, in the task table: sets `DYING` in its host-private flags and the mirror; if it is parked, sets `CANCEL_PARK` and unparks it; if it is running in user mode on some CPU, that CPU is included in the reschedule interrupt sent in the next step.
4. Sends a reschedule interrupt to every host CPU on which a task of the kernelet is running, so that each returns from user mode or reaches its next interrupt return.
5. Calls `KerneletHooks::on_dying(reason)`, on the calling task, whichever it is. This is where the endovisor cancels its device threads' outstanding host I/O ([control half](kernelet-api-control.md)).
6. Cancels the kernelet's timers on the host timer wheel and clears its pending jobs; the workers' `job_wait` returns `JOB_CANCEL`, which the worker loop turns into `task_exit`.

`kill` from `Created`, before anything ran, skips steps 3 to 6 and moves to `Exited` at once.

## Stopping a task

A task is stopped by **terminating it at its next quiescent point**, which is any point where its host-private `service_depth` is zero or where it is returning to zero. The four places a task can be when the kernelet is marked, and what stops it:

- **In a service call**, at depth one, including a park, a `job_wait` or a `user_run`: the call returns, or is cancelled and returns, and the epilogue sees `dying` and terminates the task. A `user_run` returns because of the reschedule interrupt of step 4. A hook in progress runs to completion first, which is why hooks do not sleep (register D12).
- **In kernelet code with preemption enabled**, at depth zero: the next interrupt return into `KW_TEXT`, which the tick guarantees within a millisecond, finds `DYING` in the task's flags and terminates it from the interrupt-return path.
- **In kernelet code with preemption disabled**, at depth zero: the same interrupt return terminates it regardless of the preemption count. The count protects the kernelet's own locks and per-CPU state, and a dying kernelet has no future in which those matter; the host's locks are what quiescence protects, and depth zero means none is held. This is the one place the host disregards the count.
- **Parked in kernelet-side state that never crosses**, which cannot happen: every wait in a kernelet bottoms out in `task_park` ([Tasks](virtualizing-ostd/tasks.md)).

**Termination** itself is the host's task-exit path entered from host code without returning to the kernelet: from the service epilogue, `exit_current` as `task_exit` uses it; from the interrupt-return path, the variant `preempt_switch` uses, entered with interrupts disabled. Either way the task's kernel stack, with the kernelet's frames on it, is discarded unread, the host `Task` object and its stack are reaped, the name's index is retired, and the CPU slot is cleared. No kernelet frame is resumed and no kernelet destructor runs. That is sound because at depth zero the task holds no host lock and no host object that must be released by its own code; everything host-side that the task owned is in the host's tables, which destroy drains.

The last task to stop moves the kernelet to `Exited`, records the `ExitStatus`, wakes `wait_exited`, and hands `on_exited` to a host reaper thread, so that the hook does not run on the stack being reaped. Adopted device threads are not the kernelet's tasks and are not stopped; `on_dying` told them to finish, and `destroy` waits for them to disown.

## Destroy

`destroy` runs on a host task, after `Exited`, and is the drain list made executable. Its steps, each against a field of the [per-kernelet host state](kernelet-api-control.md), in this order:

1. **Enter.** Compare-and-swap `Exited → Destroying`; wait for `ops_in_progress` to reach zero; if any run's pin count is nonzero or any adopted task has not disowned, restore `Exited`, and return `Zombie { pins }`: nothing has been released and the call is retried later.
2. **Tasks.** Assert the task table is empty of live tasks; free the table.
3. **Jobs, timers, interrupts.** Clear the pending-interrupt bitmap; remove every entry the kernelet had on the host timer wheel; the workers are gone with the tasks.
4. **Roots.** Forget the registered page-table roots; their frames are in the grant.
5. **Devices.** Drop the device table; the endovisor's models and threads were told to stop at `on_dying` and have disowned by step 1.
6. **Translations.** Flush every non-Global translation on every host CPU the kernelet ever ran on, so that no stale window translation survives the frames' reuse; one interrupt per such CPU, once.
7. **The window.** Free the host's level-2 and level-1 tables under `KW_TEXT`, `KW_DATA` and `KW_SHARED`; decrement the kind's text reference count; free the template frames, the replicas, the shared pages and the radix leaves; free the level-3 table. The level-2 tables under `KW_HEAP` are reserved frames of the runs and go with them.
8. **Memory.** For every run, in grant-table order: clear its owner-array entries, then drop the host `Segment` that holds it, which returns its frames to the host's allocator through OSTD's own frame lifecycle. The host's metadata for those frames was never written by the kernelet and needs no reset.
9. **Accounts.** Uncharge the host bytes; produce the `ReclaimReport`.
10. **Identity.** Retire the slot: advance its generation, drop the slot table's `Arc`, move to `Destroyed`, drop the hooks.

Steps 2 to 10 are the drain list, and the claim that it is complete is the one argued, not checked, claim of this page: it is complete if every field of `Kernelet` and every host-wide table that can name a `KerneletId` appears in it. The fields are enumerated on the control half's page, the host-wide tables are two, the slot table and the owner array, and both are here. A field added to `Kernelet` without a step here is the bug class to review for.

**Why release is safe.** After step 6 no CPU holds a translation for the window, after step 2 no task can run kernelet code, and after step 1 no `guest_memory` is in progress and no adopted thread is acting for the kernelet; so when step 8 returns a frame to the host allocator, nothing in the machine can reference it through a window address, and nothing in the host references it at all except through the host's own metadata, which is intact. This is invariant I4's destroy half, and it holds because the host never stored a window address anywhere but the mapping tables step 7 frees.

## What a kernelet's death does not do

- It does not run kernelet code: not a destructor, not a signal handler, not an `atexit`. A tenant that wants a clean shutdown asks its init to do one before exiting.
- It does not touch any other kernelet: no shared frame, no shared table entry, no shared lock exists between two kernelets except through the endovisor's device models, which see a connection reset ([Channels](channels.md)).
- It does not leave the host with a reference into the window, a task in its scheduler, an entry on its timer wheel, or a frame it cannot reuse.
- It does not halt the machine, for any cause in the tier-2 table, including a kernel-mode fault in the kernelet's own code.

## What a tenant sees

An exit status the runtime reports: the code its kernel passed, the panic message, or the kill reason. Processes inside the kernelet see nothing; they stop existing. Connections from other sandboxes or the host to this kernelet are reset.

## Costs

- `mark_dying`: one store to the info page; per task, one flag store and, if parked, one unpark; one reschedule interrupt per CPU running the kernelet's tasks; the `on_dying` hook.
- Per task stopped: the host's task-exit path; nothing kernelet-side.
- `destroy`: linear in tasks, runs, devices and the tables of step 7; one interrupt per CPU the kernelet ran on; per run, `Segment::drop` at one frame per page, which is OSTD's own cost for freeing a segment.
- A `Zombie` costs its grant and host objects until the pin or the adopted thread goes away; it is a sandbox in the state a process in uninterruptible sleep is in.

## What this page decides

- **A dying kernelet's tasks are terminated at depth zero regardless of their preemption count** (register D34). The alternative, honoring the count until a budget expires, would let a dying kernelet delay its own reclamation by the budget for no one's benefit.
- **Termination discards the stack rather than unwinding it** (register D35): unwinding would run kernelet code, the tenant's destructors, on the host's behalf, and could not be done at all beneath a trap frame.
- **Destroy never waits for a pin** (register D36); it returns `Zombie` and is retried. Waiting inside `destroy` on a device thread's host I/O would block the caller for as long as that I/O takes, and the caller is the runtime's process.
