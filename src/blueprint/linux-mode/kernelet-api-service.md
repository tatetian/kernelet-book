# The kernelet API: service half

*The complete list of what a running kernelet can ask of its host, given as the C interface it is, and what each request becomes on Linux. This table is the boundary: what is not on it, a kernelet cannot do.*

## What the service half is

A kernelet image has no undefined symbols, so it cannot call Linux. When the endovisor enters an image it passes a pointer to the **service table**: a C structure of twenty-one function pointers, the same for every kernelet on the machine. vOSTD calls through it whenever a [virtualized item](virtualizing-ostd/index.md) needs something only the host can give. Each such call is a **crossing**: an indirect function call at the same privilege, with no trap and no address-space switch. *Measured on the booted prototype* of the Asterinas host, a crossing cost 35 cycles against 34 for a plain call; on Linux a crossing also changes stacks ([below](#depth)), which was not measured.

The image exports the mirror image, an **entry table**, which is how the endovisor starts a task inside the image. The two tables, the shared pages and the constants are the **image ABI**. It is defined once, in a Rust module that vOSTD compiles, and the C header below is generated from that module; the endovisor's build fails if any size or offset disagrees.

Three rules shape every function in the table.

- **Arguments are integers**: task names, device numbers, physical addresses, lengths, and indices into tables the kernelet keeps. A physical address is checked against the kernelet's grant before it is used.
- **No function returns a result through a pointer.** Results come back in registers. A host that wrote through a kernelet-supplied pointer would be writing wherever a buggy vOSTD told it to.
- **The host keeps no pointer into a kernelet after a call returns.** Its tables hold identifiers and physical addresses.

## The image ABI {#abi}

```c
/* kernelet_abi.h: generated; identical on every host */

typedef uint32_t klet_task_t;            /* index:16 | generation:16; a stale name fails with -KLET_INVALID */

/* Negative returns. 1 is unused: a dying kernelet's call never returns. */
#define KLET_NOT_OWNED  2                /* a physical address outside the grant */
#define KLET_INVALID    3                /* a bad name, device, width, range or pointer */
#define KLET_LIMIT      4                /* max_grains or max_tasks reached, or Linux had no memory */
#define KLET_STATE      5                /* a call that gives up the seat, made with the no-preemption counter raised */
#define KLET_CANCEL     6                /* a sleep ended because the kernelet is dying (only seen by exempt calls) */

struct klet_user_ctx {                   /* vOSTD's UserContext begins with exactly this */
        uint64_t rax, rbx, rcx, rdx, rsi, rdi, rbp, rsp;
        uint64_t r8, r9, r10, r11, r12, r13, r14, r15;
        uint64_t rip, rflags, fsbase, gsbase;
        uint64_t trap_num, error_code, fault_addr;   /* filled in when user_run returns 1 */
};

/* job_wait() returns one of these, packed: kind in bits 0..7, payload in bits 8..39 */
#define KLET_JOB_VIRQ   1                /* payload: the line, 0..255 */
#define KLET_JOB_TICK   2                /* payload: ticks elapsed since the last one */
#define KLET_JOB_GRANT  3                /* payload: none; re-read the grant table */

#define KLET_SPAWN_SUSPENDED  1          /* task_spawn flag: do not run until task_unpark */
#define KLET_STOP_EXIT   0
#define KLET_STOP_PANIC  1
#define KLET_STOP_STACK  2

struct klet_mmio_result { int64_t status; uint64_t value; };   /* returned in two registers */

struct klet_service_table {
        uint64_t size;                                           /* of this structure, for versioning */
        /* memory */
        int64_t  (*grains_request)(uint32_t count, uint32_t contiguous);   /* >= 0: grains granted, as one run if contiguous */
        int64_t  (*pt_root_register)(uint64_t root_paddr);
        int64_t  (*pt_root_unregister)(uint64_t root_paddr);
        int64_t  (*pt_activate)(uint64_t root_paddr);            /* 0 means "no tenant address space" */
        int64_t  (*tlb_shootdown)(uint64_t root_paddr, uint64_t start, uint64_t len);   /* len == UINT64_MAX: everything */
        /* tasks */
        int64_t  (*task_spawn)(uint32_t entry, uint64_t arg, uint64_t seat_mask, int32_t nice, uint32_t flags);  /* >= 0: a klet_task_t */
        void     (*task_exit)(void);                             /* does not return */
        int64_t  (*task_destroy)(klet_task_t name);              /* only a task that never ran */
        void     (*task_yield)(void);
        int64_t  (*task_park)(void);                             /* 0, or -KLET_CANCEL */
        int64_t  (*task_unpark)(klet_task_t name);
        int64_t  (*task_set_nice)(klet_task_t name, int32_t nice);
        int64_t  (*task_set_seats)(klet_task_t name, uint64_t seat_mask);
        /* jobs and time */
        int64_t  (*job_wait)(void);                              /* a packed job; never returns to a dying kernelet */
        int64_t  (*timer_arm)(uint32_t seat, uint64_t deadline_ns);   /* UINT64_MAX cancels */
        /* user mode */
        int64_t  (*user_run)(struct klet_user_ctx *ctx);         /* 0 system call, 1 exception, 2 look for kernel events */
        /* devices */
        struct klet_mmio_result (*mmio_read)(uint32_t dev, uint32_t offset, uint32_t width);
        int64_t  (*mmio_write)(uint32_t dev, uint32_t offset, uint32_t width, uint64_t value);
        /* output and end of life */
        int64_t  (*log_write)(uint32_t level, const char *module, uint32_t module_len, const char *text, uint32_t text_len);
        int64_t  (*oops)(const char *msg, uint32_t len);
        void     (*stop)(uint32_t kind, uint32_t code, const char *msg, uint32_t len);   /* does not return */
};

struct klet_entry_table {                /* in the image, 4 KiB from its base; read-only */
        uint64_t size;
        void     (*run_task)(uint32_t entry, uint64_t arg);      /* the body of every task but the boot task */
        uint64_t cpu_local_start, cpu_local_end;                 /* the section to copy once per seat */
        uint8_t  source_hash[32];
};
/* The boot task is entered at the ELF entry point: void _kernelet_entry(const struct klet_service_table *, const struct klet_boot_args *) */
```

**How a task starts.** The kernel proper hands vOSTD a Rust closure. A closure cannot cross the boundary, so vOSTD stores it in a table of its own and passes the *index* as `entry`. The new carrier enters the image through `run_task(entry, arg)`, and vOSTD looks the closure up and runs it. Index 1 is reserved for the [worker](virtualizing-ostd/interrupts-and-time.md) body, with `arg` its seat. The endovisor never sees a function pointer into the image other than the two in the entry table.

## Who is calling {#depth}

No service takes a "which kernelet" argument, because a kernelet must not be able to claim to be another. The endovisor finds the caller from Linux: the current task's [gate pointer](virtualizing-ostd/user-mode.md) leads to its **carrier record**, which names the kernelet, the kernelet task, the [seat](virtualizing-ostd/tasks.md#seats) the carrier holds, and the **service-call depth**. The record is endovisor memory that no kernelet can address.

Every service function is wrapped in the same prologue and epilogue.

**On the way in**: find the carrier record; if the kernelet is marked dying, do not return to it at all but [leave the kernelet for good](faults-and-reclamation.md#leaving) (three calls are exempt, because a dying kernelet's tasks must still be able to make them: `stop`, `task_exit` and `task_park`); set the depth to 1; count the call for the sandbox's statistics.

**On the way out**: set the depth to 0; if the kernelet was marked dying meanwhile, leave for good instead of returning.

The depth is 1 exactly while the carrier, having come from kernelet code, is inside endovisor or Linux code and may hold their locks. It is one of the two tests that make [eviction](faults-and-reclamation.md#eviction) safe.

**Two kinds of call, with respect to the seat.** `task_park`, `task_yield` and `job_wait` exist to let others run: they give up the seat, sleep in Linux, and take a seat again before returning. vOSTD must not make them while its no-preemption counter is raised, because the kernel proper's code between raising and lowering it assumes its per-CPU data is not touched by anyone else; the prologue checks the counter, which is on a page the kernelet writes, and answers `-KLET_STATE`. That check protects the kernelet from its own bugs, not the host from the kernelet, so it does not matter that the kernelet could lie. Every other call keeps the seat. Four of those can block inside Linux: `grains_request` and `task_spawn` while Linux allocates memory, `pt_activate` while it creates an area, and `tlb_shootdown` while it waits for fault handlers to finish. The seat stays taken meanwhile, which is correct, since a processor that is waiting for a TLB flush is not available either. `tlb_shootdown` cannot be allowed to fail, so it is never refused for the counter's sake.

A carrier inside a service call cannot be [evicted](faults-and-reclamation.md#eviction), so the endovisor owes a bound on every one of them. The rule is that **every sleep inside a service is killable**: the waits use Linux's killable forms, and the sweep's `SIGKILL` ends them. The remaining services do bounded work without sleeping.

**Stack.** A service call does not run on the [kernelet stack](virtualizing-ostd/tasks.md). Each entry in the table is a short stub in the endovisor that switches to the carrier's Linux stack, runs the prologue, the service and the epilogue there, and switches back. Linux's code then runs on the stack it was written for, one that Linux's overflow detection and backtraces know about, and how deep a service goes into Linux no longer depends on how deep the kernelet was when it called. The Linux stack is nearly empty at that moment: it holds only the frames of the gate hook that entered the kernelet. The cost is two stack switches per service call, a few nanoseconds.

## What each service becomes on Linux

| service | on Linux |
|---|---|
| `grains_request` | page allocator or contiguous allocator, charged to the sandbox's control group; zero; record in the owner array, then publish in the grant table ([Memory](virtualizing-ostd/memory.md)) |
| `pt_root_register` | check that the root frame is in the grant; create the model's record and its file object |
| `pt_root_unregister` | empty every cache of the model; drop the record |
| `pt_activate` | bind the calling carrier to the model; if its area was caching another model, replace the area |
| `tlb_shootdown` | wait out fault handlers on this model, then `unmap_mapping_range()` on the model's file, which empties the range in every carrier's cache ([Memory](virtualizing-ostd/memory.md#interlock)) |
| `task_spawn` | queue a request to the root carrier, which clones a carrier ([Tasks](virtualizing-ostd/tasks.md#root)); the name is returned at once |
| `task_exit` | the carrier [leaves for good](faults-and-reclamation.md#leaving) |
| `task_destroy` | cancel the request, or let the suspended carrier exit without entering the image |
| `task_yield` | give up the seat; Linux's `cond_resched()`; take a seat |
| `task_park` | give up the seat; killable sleep until unparked; take a seat. An unpark that arrives first is remembered, so a wake is never lost |
| `task_unpark` | `wake_up_process()` on the carrier; also what releases a task spawned suspended |
| `task_set_nice` | `set_user_nice()` |
| `task_set_seats` | restrict the seats the task may take |
| `job_wait` | killable sleep on the seat's job queue ([Interrupts and time](virtualizing-ostd/interrupts-and-time.md)) |
| `timer_arm` | re-arm the seat's `hrtimer` |
| `user_run` | switch to the Linux stack and return to user mode through the gate ([User mode](virtualizing-ostd/user-mode.md#user-run)) |
| `mmio_read`, `mmio_write` | check device, offset and width (1, 2, 4 or 8); call the device model ([Devices](virtualizing-ostd/devices.md)) |
| `log_write` | copy at most 1 KiB into the sandbox's log ring, rate-limited |
| `oops` | count a caught panic against the oops budget |
| `stop` | mark dying with the kind, code and message; never returns |

**Pointers.** Four services take one. `user_run`'s context must lie on the caller's own kernelet stack, which the endovisor allocated and the kernelet cannot unmap, and the endovisor copies it rather than using it in place. The text arguments of `log_write`, `oops` and `stop` are read with Linux's non-faulting kernel copy, [`copy_from_kernel_nofault()`](https://elixir.bootlin.com/linux/v6.12/source/mm/maccess.c#L24), after a check that the range lies in the instance's image, stack or grant, so a bad pointer is `-KLET_INVALID` and never a host fault.

## The shared pages {#pages}

Some information is cheaper to read than to ask for. The endovisor maps six kinds of page after each instance's data; all are read-only to the kernelet except the last two.

| page | contents | written |
|---|---|---|
| **boot arguments** | identity, number of seats, direct-map base, metadata base, where the other pages are, device list, command line, and the two offsets vOSTD needs to find its carrier record from Linux's current-task pointer | once, before entry |
| **grant table** | the base and length of each run | appended by the endovisor when it grants |
| **info page** | the dying flag, the number of runs | by the endovisor |
| **clock page** | coarse ticks and monotonic nanoseconds; one page for the whole machine | by one machine-wide timer |
| **task records** | per task: the no-preemption counter | by vOSTD |
| **seat records** | per seat: pending tick count, RCU quiescence | by both |

Nothing a kernelet can write on these pages is believed by the endovisor for any decision that protects the host. The depth, the dying mark that the endovisor acts on, and the ownership of seats are all in endovisor memory.

## What is not offered

There is no service to read or write host memory, to map anything, to allocate a frame by address, to disable interrupts, to send an interrupt, to load a page table into the processor, or to call a host function by address. Their absence from the table is what makes them absent from a kernelet. The image cannot name what the table does not contain.

## What this page decides

- **The service table is the same twenty-one functions on both hosts** (register D2 and D65, kept). Linux changes what stands behind each, never the table. A kernelet image differs between hosts only in the three vOSTD bodies listed under [Virtualizing OSTD](virtualizing-ostd/index.md).
- **Service calls run on the carrier's Linux stack** (register D112). The alternative, running Linux's code on the kernelet stack behind a reserve, rests on a bound that cannot be argued and whose failure halts the machine.
- **The caller is identified through Linux's current task, and the depth and dying state live in endovisor memory** (register D7 and D8, adapted). The alternative, state in shared pages, would let a kernelet make itself unstoppable.
