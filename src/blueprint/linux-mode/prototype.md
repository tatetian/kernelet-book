# The prototype

*What has been verified by running code, what each run showed, and what has not been verified at all. The chapter's claims are only as strong as this page.*

## What was built, at a glance

| what | shows | standing |
|---|---|---|
| **Hello World on the design's real path**: the Asterinas tree's 100-line kernel, source unchanged, as a kernelet in a patched Linux 6.12 | the gate, carriers and the root carrier, kernelet stacks, `user_run`, the model and the cache, tenant copies by walking the model, entry and exit | *measured on the booted prototype*, [below](#hello) |
| **The software walk, in a model** | the cost the design adds to every tenant copy, and that the supervisor alias does not earn its risks | *measured in a model*, [below](#walk) |
| **Earlier mechanism experiments** (in a Linux 6.12 guest) | shared text for many instances; the cost of a gate; Linux's refusal of executable `vmap` memory; SMAP's refusal of direct tenant access; recovery from a kernel-mode fault by die notifier | *measured on the booted prototype of each mechanism*, [below](#earlier) |
| eviction, the function-entry stack check, exceptions through the resume hook, multi-instance loading of a real image, the device models, channels, the runtime, more than one seat | nothing | **[unverified]**: designed, not built |

No full kernelet, meaning the Linux-compatible kernel proper with its file systems and network stack, has run on Linux. What has run is a small kernel written against the same OSTD interface, which uses the interface's hardest parts.

## Hello World on the design's real path {#hello}

**The test.** The Asterinas tree has a teaching example, [a kernel in about 100 lines of safe Rust](https://github.com/asterinas/asterinas/blob/main/book/src/ostd/a-100-line-kernel.md). It allocates frames, copies a user program into them, builds an address space and maps the frames into it, creates a task, enters user mode with `UserMode::execute`, and services two system calls, `write` and `exit`. Small as it is, it uses the parts of OSTD's interface that are hardest to provide on Linux: tasks, a tenant address space, user-mode entry with a returning `execute`, and fallible reads of tenant memory.

**The rule.** The kernel's source file is copied from the tree (commit `ab9a4cfdc`) and the build compares it byte for byte with the original before every run. Only its `Cargo.toml` differs: the dependency named `ostd` resolves to the prototype's vOSTD. If an OSTD item could not keep its path or signature on Linux, that would be a finding. None needed to change.

**The layers**, as built, in a git worktree of the Asterinas repository under `kernelet-linux/`:

| layer | what it is | size |
|---|---|---|
| kernel proper | the 100-line kernel, unchanged, `deny(unsafe_code)` | 136 lines of Rust, 18 of assembly for the user program |
| vOSTD | a Rust crate whose library name is `ostd`, offering the items that kernel uses with their real signatures. It calls no Linux symbol: the linked image has zero undefined symbols | 2,307 lines |
| image ABI | a service table and an entry table of C function pointers, and boot arguments | in both of the above |
| endovisor | one Linux module in C: the program loader and root carrier, carriers by `kernel_clone()`, the stack switch, the gate's two hooks, the memory area and its fault handler with the model walk and the grant check, nine services | 1,487 lines |
| the gate | a patch to Linux v6.12 | 103 added lines in 8 files, none removed |
| runtime | a static test program that forks, sets *no new privileges* and executes the sandbox file | 154 lines |

**The run.** Linux 6.12.0, built from `tinyconfig` plus a fragment (SMP, full preemption, modules, seccomp, control groups, address-space randomization), patched, booted in QEMU with hardware virtualization and two processors. One command, `make hello`, builds everything, boots, and checks the serial log. This is the log, unedited except for the boot messages before it:

```
INIT: loading kernelet.ko
kernelet: endovisor loaded: grant 4096 KiB at 0x800000, linear map 0xffff907640000000, 1 seat
INIT: running /tests/10-hello
RUN-HELLO: creating a sandbox from /hello.klet
kernelet: root carrier exec (pid 32), address space emptied
kernelet: boot carrier starting (pid 33)
kernelet: vOSTD up: grant 0x800000..0xc00000, linear map 0xffff907640000000, 1 seat(s)
kernelet: boot carrier (pid 33) activated the model at 0x803000
kernelet: user carrier starting (pid 34)
kernelet: user carrier (pid 34) user window [0x10000, 0x7fffffffe000)
kernelet: cache fill pid 34: va 0x401000 <- pa 0x801000 (rwx)
kernelet: syscall 1 serviced by the kernelet (pid 34)
kernelet: Hello, world
kernelet: 
kernelet: syscall 60 serviced by the kernelet (pid 34)
kernelet: stopped, exit code 0
kernelet: boot carrier (pid 33) dying
kernelet: root carrier (pid 32) dying
kernelet: user carrier (pid 34) dying
RUN-HELLO: root carrier (pid 32) killed by signal 9
kernelet: user window of pid 34 closed by Linux
RUN-HELLO: no carrier left (module references: 0)
RUN-HELLO: done
INIT: unloading kernelet
kernelet: endovisor unloaded
INIT: done
```

Read against the design, line by line:

- *root carrier exec*: the runtime's child executed a file beginning with the magic `KLET`; the endovisor's [binary-format handler](virtualizing-ostd/tasks.md#root) claimed it and emptied the address space.
- *boot carrier*, *user carrier*: two `kernel_clone()`s by the root carrier, one per OSTD task. Each is a separate Linux process (pids 33 and 34).
- *activated the model at 0x803000*: `VmSpace::activate` became `pt_activate`; the root of the kernel proper's page table is a frame of the grant (which starts at 0x800000), and nothing was written to the processor's page-table register.
- *user window*: on the user task's first `user_run`, one memory area covering the user range, created with `vm_mmap()`.
- *cache fill*: the tenant's first instruction fetch faulted in Linux; the endovisor's handler walked the model, checked the frame against the grant, and installed the translation. There is exactly one fill, although the program's message is on another page: the kernel proper read the message [by walking the model](virtualizing-ostd/memory.md#copies), which involves no Linux page table at all.
- *syscall 1 serviced by the kernelet*, *Hello, world*: the [gate](virtualizing-ostd/user-mode.md)'s syscall hook switched to the kernelet stack, `UserMode::execute` returned `UserSyscall`, and the kernel proper's own handler printed the buffer with `println!`, which is the `log_write` service. Linux's `write` was never called.
- *stopped, exit code 0*: `power::poweroff` became the `stop` service; every carrier was killed, the area's `close` callback fired, the module's reference count reached zero, and the module unloaded.

The checks (`Hello, world`; exit code 0; clean unload; no `BUG:`, `Oops`, `WARNING:` or `Call Trace` in the log) passed on three consecutive runs of the final tree.

**Two paths not on the hello kernel's route were forced, once each, with temporary instrumentation that was then removed.** A forced *model miss* on the first fault made the handler record the fault and return; the resume hook resumed the kernelet with `user_run` returning *exception* (trap 14); the kernel proper ignored it and called `execute` again; the second fault was filled and the program ran to completion. A forced `tlb_shootdown` between the two system calls removed the cached translation, and the log shows it being filled again on the next instruction fetch.

**What the prototype does not have**, and therefore does not show: more than one kernelet, more than one seat, the position-independent loader (the image is linked into the module), eviction, the die notifier, the function-entry stack check, exceptions other than page faults, the FS base and floating-point paths, devices, channels, a real runtime, control-group accounting of the grant, and any synchronization between the fault handler's walk of the model and a concurrent change to it. Its Rust heap is Linux's `kmalloc`, where the design puts the heap in the grant. Implemented but never executed: the write-protection callback, the "present but not permitted" flavor of a model miss, and the refusal of non-64-bit entries.

## The walk, measured {#walk}

The design replaces a direct dereference of tenant memory with a software walk of the [model](virtualizing-ostd/memory.md#copies) followed by a copy through Linux's direct map. Before adopting it, its cost was measured against the two alternatives, in user space on the development machine (Intel Xeon E3-1270 v6, Linux 6.8, gcc 11 `-O2`, one pinned core; medians of five runs).

**The model.** A four-level page table in hardware format was built in user memory, with its nodes placed at shuffled positions so that the walk gets no locality a kernel would not have, over a synthetic process layout of up to a million mapped pages. The walk is four dependent loads with a present-bit test at each level, compiled in its own unit so that the compiler cannot fold it away.

**The three ways to copy.** One set of pages was mapped three times: a *tenant* mapping with 4 KiB pages; an *alias*, a second 4 KiB mapping, standing for the supervisor alias; and a *direct map* on 2 MiB pages, standing for Linux's. A "tenant" touch of a random page in a working set of W pages was followed by a copy of L bytes out of that page, by each route.

| | W = 64 pages | W = 4,096 | W = 262,144 |
|---|---|---|---|
| a walk alone, random page | 3.6 ns (15 cycles) | 4.7 to 5.3 ns | 13.3 ns (55 cycles) |
| a walk alone, its four entries flushed from cache first | about 300 ns | about 300 ns | about 300 ns |
| copy 16 B: direct / alias / **walk + direct map** | 2.6 / 4.7 / **12.1** ns | 2.6 / 8.4 / **13.2** ns | 2.6 / 17.4 / **23.7** ns |
| copy 4 KiB: direct / alias / **walk + direct map** | 81 / 81 / **89** ns | 245 / 266 / **265** ns | 289 / 373 / **362** ns |

The copy figures have the measurement harness's own 9 ns subtracted. The alias took one more hardware page walk per operation than the direct route (*measured* with the processor's TLB-miss counter); the walk-plus-direct-map route took 0.15 more. For scale, one `getppid` system call on the same machine, with its speculative-execution mitigations, took 479 to 497 ns.

**What this decided.** The walk adds about 10 ns to a small copy and nothing measurable to a large one, so the model stays as designed. The supervisor alias would save about 7 ns on small copies with a small working set, and nothing with a large one, because the second set of 4 KiB translations it needs costs TLB misses that the 2 MiB direct map does not. That does not pay for writing page-table entries Linux believes it owns, so the alias is [rejected](alternatives.md). An 8-entry cache of recent leaf tables in front of the walk recovered about 5 ns in the small case, and with a realistic address-space layout and a larger working set its hit rate fell below 10 percent and it was slower than the plain walk. It was left out.

**What this does not show.** It is a model in user space on one machine, not vOSTD in a kernel. The 256-byte cells at the largest working set varied by a factor of two between runs on this shared machine and are not quoted. The sources, the commands and every table are in the prototype's `kernelet-linux/bench/`, with the raw output in `RESULTS.md`.

## Earlier experiments {#earlier}

Nine experiments were run while the design was being worked out: six numbered ones on the mechanisms this design uses, fault recovery, and two on designs that were [rejected](alternatives.md). Two machines were involved, and their numbers are never compared with each other. The **build host** is the development machine above, where a bare system call costs about 485 ns. The **guest** is Linux 6.12.0 built from `tinyconfig` plus what a virtual machine and loadable modules need, booted under hardware virtualization on that host; a bare system call there costs 44 ns, because the configuration has none of the mitigations. Read the differences, not the ratios: a floor ten times lower flatters every ratio.

**1. Two instances of one image.** The same module source, built under two names and loaded together: each copy had its own data at its own address and ran its own initializer. Linux refuses a second copy of a module by name only. *Shows:* relocating one image twice gives two independent sets of globals.

**2. One physical text page, four instances.** One page of position-independent machine code (`mov rax, [rip+d]; ret`), mapped four times with `vmap()`, each mapping followed by a different data page:

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

*Shows:* the whole of the [loading scheme](builds-and-images.md#sharing). It needed `set_memory_rox()` to be exported: the first attempt executed from a plain `vmap()` range and Linux reported `kernel tried to execute NX-protected page`. With the export, the text's page-table entry read `W=0 X=1`.

**3. The cost of a gate.** One program, in the guest, timed with the cycle counter; medians of five runs.

| path | median | over a bare call |
|---|---|---|
| a call Linux services itself (`getppid`) | 44 ns | — |
| Syscall User Dispatch, no kernel change | ≥ 929 ns | + 885 ns |
| a per-task hook that returns a constant | 39 ns | below the noise |

The hook measured below `getppid` because its servicer did no work. What the row shows is that a hook adds nothing measurable to Linux's entry path. That hook sat in x86-64's own entry code; the [gate](virtualizing-ostd/user-mode.md) is in the generic layer one call further in, and its cost with the stack switch and the seat is **not measured**. On the build host, seccomp user notification cost 5,721 ns per call and `ptrace` 8,221 ns, against 1,887 ns for dispatch there.

**4. Where relocations land.** A Rust static library with the shapes a kernel image is full of, linked as a kernelet image would be: `.text` 274,307 bytes and `.rodata` 64,914 bytes with no relocations; 181 in `.data.rel.ro` and 119 in `.got`, all of the one base-relative type. *Shows:* 98 percent of the read-only material can be shared. It is a synthetic library, not the kernelet image.

**5. Indirect-branch markers.** With the compiler flag that asks for them, the library's entry function began with the landing marker that hardware control-flow enforcement checks. *Shows:* the compiler half of [assumption A19](builds-and-images.md#audit). The kernel half is open.

**6. Can kernel-mode code touch a tenant address?** Six cases, in the guest, with SMAP on, each in a forked child so that a fatal case does not end the run:

```
smap_test: the cell holds 5a5a5a5a5a5a5a5a at 0x4c70f0
  bare read        -> child KILLED by signal 9
  module-bracketed -> OK
  copy_from_user   -> OK
  direct-map alias -> OK
  bracketed, bad   -> child KILLED by signal 9
  bad, with fixup  -> OK          (smapdemo: recovered from the fault, fail=-14)
```

*Shows:* a bare kernel-mode read of a mapped, present tenant page ends the task; the same frame read through the direct map needs nothing; and setting the processor flag around the access works for a good address and is fatal for a bad one unless Linux finds a recovery entry, which it does only for its own code and for modules. This is the experiment behind [never dereferencing a tenant address](virtualizing-ostd/memory.md#copies).

**Fault recovery by die notifier.** In the same series, a module registered a die notifier that recognized a fault in its own text, moved the saved instruction pointer, and answered `NOTIFY_STOP`; the faulting process survived, twice, and a full oops was printed each time. A divide error in kernel mode was survived the same way. *Shows:* the mechanism of [fault containment](faults-and-reclamation.md#fault), and its price.

**Two rejected designs, measured.** A supervisor-only alias of a tenant's page table was built: a bare kernel-mode read through it succeeded where the same read through the tenant's address was fatal, at 0.92 cycles per access against 1.08 for an ordinary kernel address and 38 for Linux's bracketed `get_user`; its cost in TLB entries is what [the model above](#walk) measured later. And one Linux task was made to carry two tenant threads, swapping register file, thread pointer and floating-point state 400,000 times: a switch cost 291 ns more than a serviced call that stays on one thread, 91 ns of it floating-point state. A third figure quoted among the alternatives comes from the same series: code run in kernel mode of a hardware-virtualized guest, on the build host, paid 792 ns (3,002 cycles) for an exit and resume, and its second level of address translation cost nothing measurable while translations were resident and a factor of 1.20 on memory access at a working set too large for the TLB.

The programs and unedited transcripts of these experiments were in the book's notes until this chapter replaced them; they are in the repository's history.

## Findings {#findings}

Building the prototype changed the design in eight places. Each finding below has been folded into the page named, so the design and the prototype agree; the last column of the table after it records where the *prototype* still differs from the design, which are its shortcuts and not open questions.

1. **OSTD's address-space activation is per CPU, and the 100-line kernel relies on it.** Its `main` activates the address space, and a *different* task enters user mode. With activation recorded per task, which is what both hosts need, that task would have no address space. A new task therefore inherits its creator's activation, weakly, until it activates one of its own ([Memory](virtualizing-ostd/memory.md#cache)). The finding applies to the Asterinas host too.
2. **`Task::yield_now()` from the boot context must not return while tasks exist.** On a machine it never does. The first prototype returned at once, and the start-up code that follows `main` powered the kernelet off before its task had run ([The rest](virtualizing-ostd/the-rest.md)).
3. **Linux grants write permission behind a fault handler's back.** A write to a cached read-only translation does not call the area's `fault` function; without a `pfn_mkwrite` callback Linux simply makes the entry writable. The endovisor must supply that callback and consult the model in it ([Memory](virtualizing-ostd/memory.md#cache)).
4. **A read or fetch that violates a cached translation's permissions never reaches the area at all.** Linux raises `SIGSEGV` directly. The design already turns forced signals back into exceptions in the resume hook, so the case is covered, by that path and not by the fault handler ([Memory](virtualizing-ostd/memory.md#cache)).
5. **Inserting a translation over an existing one silently does nothing.** So the handler must always install the model leaf's *full* permissions, never only what the faulting access needed, or the next wider access would fault forever.
6. **Module lifetime is not quite automatic.** Linux's per-address-space reference on the program loader's module is dropped before the last reference to the area's file is, and the file's release ran in unloaded code, once. The file operations must name the module as their owner ([Tasks](virtualizing-ostd/tasks.md#root)).
7. **Every carrier inherits the root carrier's saved registers**, including its segment selectors and flags, because a clone that starts in a kernel function copies its parent's register file. The root carrier must therefore initialize its own as a 64-bit user task even though it never reaches user mode ([Tasks](virtualizing-ostd/tasks.md#root)).
8. **A Rust image for Linux's module loader needs `-Z plt=yes`.** Without it the compiler reaches its own helper functions through a global offset table, 1,593 relocations of a kind the loader rejects. This affects the prototype's build only; the design's [position-independent image](builds-and-images.md) is loaded by the endovisor, not by Linux's module loader.

| OSTD item the kernel uses | service | Linux facility | prototype differs from the design in |
|---|---|---|---|
| `#[ostd::main]` | — | the tree's own macro crate, unchanged; entered on the boot carrier | — |
| `println!` | `log_write` | `printk` | the design's per-sandbox log ring |
| `power::poweroff` | `stop` | `SIGKILL` to every carrier; the calling kernelet stack is abandoned | — |
| `Box`, `Vec`, `Arc` | two heap services | `kmalloc` | the design's heap lives in the grant and needs no service |
| `FrameAllocOptions`, `Frame`, `Segment`, `UFrame` | — | a bitmap over one 4 MiB run from `alloc_pages()` | one fixed run; no `grains_request`, no accounting flag, no owner array beyond one range check |
| `VmSpace::new`, `cursor_mut`, `CursorMut::map` | — | none: a hardware-format page table in grant frames | — |
| `VmSpace::activate` | `pt_activate` | a field in the carrier record | — |
| `VmSpace::reader`, `VmReader::read_fallible` | `pt_current` | none: a walk of the model in vOSTD, then Linux's direct map | `pt_current` is an extra service; in the design vOSTD remembers the activation itself |
| `disable_preempt` | — | a counter | — |
| `TaskOptions`, `Task::run` | `task_spawn` | a request to the root carrier; `kernel_clone()` with a start function | no priority or affinity |
| `Task::yield_now` (boot context) | an idle wait | give up the seat; sleep until no task is left | — |
| `UserMode::execute`, `UserContext` | `user_run` | the stack switch, `pt_regs`, the gate's two hooks | no FS base, no floating-point state |
| (the cache) | `tlb_shootdown` | one raw-frame-number area per carrier; `fault` walks the model; `zap_vma_ptes()` | no interlock with concurrent model changes; one list of carriers instead of a file per model |

**Reproducing it.** In the worktree, `cd kernelet-linux && make hello`. The first run downloads nothing: it expects the Linux 6.12 tree unpacked under `.build/`, which `make linux` prepares. `REPORT.md` there lists every deviation and surprise met during the build, 27 in all, most of them engineering.
