# Background: the Linux this chapter needs

*Everything about Linux that the rest of the chapter uses, defined before it is used. A reader who knows what a kernel, a page table and a system call are, but has never worked on Linux, should be able to read this page once and then read the rest without stopping. Every claim links to Linux's own source or documentation, pinned to **version 6.12**, which is the long-term release this chapter was tested against.*

## The kernel's own address space

Every process on Linux has one page table. Its lower half describes the process; its upper half describes the kernel and is **the same in every process**. Linux keeps it that way deliberately: when the processor enters the kernel it must find the kernel already mapped, whichever process it came from.

Four regions of that upper half matter here. Their addresses come from [Documentation/arch/x86/x86_64/mm.rst](https://docs.kernel.org/arch/x86/x86_64/mm.html), whose sizes are binary quantities written with decimal-looking prefixes — the direct map's "64 TB" is 2⁴⁶ bytes, which is 64 TiB, and the module region's "1520 MB" is 1520 MiB. The arithmetic later in the chapter is binary throughout:

| region | what it holds | size, 4-level paging | size, 5-level paging |
|---|---|---|---|
| the **direct map** | every byte of physical memory, once, in order | 64 TB | 32 PB |
| the **vmalloc area** | ranges the kernel assembles out of scattered pages | 32 TB | 12.5 PB |
| the **module area** | code loaded after boot | 1520 MB, or 1008 MiB with address randomization | the same |
| kernel text | the kernel's own code | 512 MB | 512 MB |

Two of these deserve a closer look.

**The direct map** is the one that matters most. Because all of physical memory appears there in order, converting a physical address to a usable kernel address is a single addition. Linux spells it [`__va(x)`](https://elixir.bootlin.com/linux/v6.12/source/arch/x86/include/asm/page.h#L58), which is literally `x + PAGE_OFFSET`. That is the same shape as OSTD's own `paddr_to_vaddr`, and the chapter leans on the coincidence. `PAGE_OFFSET` is not always a compile-time constant: on a kernel built with memory-layout randomization it expands to the variable [`page_offset_base`](https://elixir.bootlin.com/linux/v6.12/source/arch/x86/kernel/head64.c#L64), which is exported to modules and which does not exist at all on a kernel built without that option. So a module should use `PAGE_OFFSET`, not the variable, and let the header pick. That export carries no license restriction; most of Linux's newer ones do, and the symbols this chapter asks to have exported would, so the endovisor module must declare a compatible license.

**Paging levels.** An x86-64 processor walks either four or five levels of page table. Five-level paging, present on server processors from Ice Lake onward, widens the vmalloc area by about 400× and the direct map by 512×; the module area and kernel text are the same size either way, as the table shows. The chapter states where that matters; mostly it is the difference between a few thousand kernelets per machine and as many as anyone would want.

## Loadable modules

A **module** is kernel code loaded after boot. It is an ordinary relocatable object file: Linux allocates memory for it, then walks its relocation entries and patches each reference to its final address, exactly as a linker would. The relocation types x86-64 accepts are in [`arch/x86/kernel/module.c`](https://elixir.bootlin.com/linux/v6.12/source/arch/x86/kernel/module.c#L118).

Three facts about modules shape this chapter.

**Each loaded copy has its own data.** A module's global variables live in the memory Linux allocated for that load. Load the same code twice and you get two independent sets of globals. This is [measured](evidence.md), not assumed.

**Linux refuses a second copy only by name.** The check is a string comparison against the list of loaded modules ([`kernel/module/main.c`](https://elixir.bootlin.com/linux/v6.12/source/kernel/module/main.c#L2674)); rename the module and a second copy loads — after also renaming any symbol it exports, since a duplicate exported symbol is refused separately. That is a fact about the loader, not a design we build on, but it tells us the obstacle is bookkeeping rather than anything deeper.

**Module code must live in the module area, and that area is small.** Kernel code is compiled so that any reference to another piece of kernel code or data must fit in a signed 32-bit offset, which confines it to a 2 GB span. Linux therefore reserves 1520 MB for all modules together — and less than that in practice, because the region is what is left after the kernel image, which reserves twice as much when address randomization is on. On a kernel anyone ships, it is **1008 MiB**. In v6.12 the allocator behind this is [`execmem`](https://elixir.bootlin.com/linux/v6.12/source/mm/execmem.c), which replaced the older `module_alloc`, and on x86-64 it has no fallback into the roomier vmalloc area ([`arch/x86/mm/init.c`](https://elixir.bootlin.com/linux/v6.12/source/arch/x86/mm/init.c#L1056)).

## Getting memory, and the executable-memory problem

A module that wants a stretch of kernel addresses backed by pages it chose calls [`vmap()`](https://elixir.bootlin.com/linux/v6.12/source/mm/vmalloc.c#L3453): hand it an array of pages and it returns one contiguous kernel address for them. It is exported to modules. This is how the chapter builds each kernelet's image.

There is a catch, and it is the first thing Linux mode needs changed. **`vmap()` will not give you executable memory.** Its implementation wraps the caller's requested permissions in `pgprot_nx()`, which clears the execute bit, so asking for executable memory and getting non-executable memory is not an error — it is the documented behavior, visible in the source. Nor is there another route: [`arch/x86/mm/pat/set_memory.c`](https://elixir.bootlin.com/linux/v6.12/source/arch/x86/mm/pat/set_memory.c) exports helpers that change *caching* but exports no helper that changes *permissions*, and `execmem_alloc()` is not exported at all.

So an out-of-tree module has no supported way to make memory executable at an address of its choosing. The [evidence](evidence.md) page shows what that looks like when you try, and the exports that fix it.

## Kernel threads

A **kernel thread** is a schedulable thread that only ever runs kernel code; it has no user-space side. A module creates one with [`kthread_run()`](https://elixir.bootlin.com/linux/v6.12/source/kernel/kthread.c), or, to pin it to a chosen processor, with the variant that binds it before it is woken — binding a thread that is already running is refused. Kernelet tasks become kernel threads.

A kernel thread may temporarily borrow a process's address space with `kthread_use_mm()`, which is how it reads and writes that process's memory. It cannot return to user mode as the thread it is. Linux does have one path that turns a kernel thread into a user one — it is how the first user process is started — but that path loads a fresh program from a file, and it is not available to a module. Nothing lets a module return a kernel thread into a user context of its choosing, which is what a kernelet would need.

## Processes, address spaces, and faults

A process's address space is a list of **virtual memory areas**. Each area covers a range of addresses and names the code that owns it. When the processor faults on an address, Linux finds the area and calls its owner's **fault handler** to supply the page.

**One rule about user memory matters more than anything else on this page.** Since Broadwell and Zen, an x86-64 processor refuses a kernel-mode access to a page marked as user memory unless one flag in the processor's status register is set. Linux sets it for the length of a copy and clears it again, with the [`stac` and `clac`](https://elixir.bootlin.com/linux/v6.12/source/arch/x86/include/asm/smap.h) instructions, which is why its own copy routines are the only code it allows to touch user memory. [`do_user_addr_fault()`](https://elixir.bootlin.com/linux/v6.12/source/arch/x86/mm/fault.c#L1257) checks the flag before it looks the address up in the process's areas and before it searches for a fixup, and reports a bad kernel pointer if it is clear. A kernel that enables this and one that does not are different environments for the same code, which is the subject of a [later page](not-as-assumed.md).

The area's fault handler is an ordinary function pointer a driver provides, through a structure called `vm_operations_struct`. This is a completely standard, unpatched Linux mechanism — it is how graphics drivers hand device memory to programs — and this chapter uses it to let a kernelet own its tenant's memory: the kernelet supplies the pages, out of its own grant, at the moment the tenant touches them.

## How a system call reaches the kernel, and who may intercept it

On x86-64 a program executes the `syscall` instruction. The processor enters the kernel, and Linux runs [`do_syscall_64()`](https://elixir.bootlin.com/linux/v6.12/source/arch/x86/entry/common.c), which looks the call number up in a table and calls the handler.

Two notes on that sentence. On x86-64 the table is no longer a table of pointers the processor indexes: since v6.9 the dispatch is a `switch` the compiler turns into a jump, and the array survives for tracing. And "looks the call number up" hides the work before it — the audit and tracing machinery in [`kernel/entry/common.c`](https://elixir.bootlin.com/linux/v6.12/source/kernel/entry/common.c#L28), which runs first.

Within that machinery there are exactly three places where a call can be **answered by something other than Linux**, in this order:

They run in the order given here, which is the order in [`syscall_trace_enter()`](https://elixir.bootlin.com/linux/v6.12/source/kernel/entry/common.c#L28): dispatch, then ptrace, then seccomp.

**Syscall User Dispatch.** A process asks Linux, once, to stop executing its system calls and instead deliver a signal. Which calls are diverted is decided by a **single byte in the process's own memory**: when it reads *allow*, calls run normally; when it reads *block*, each one raises `SIGSYS` instead. Flipping that byte costs no system call, which is what makes the mechanism fast. It was built for Windows emulators, which must run a foreign program's calls themselves. See [the manual](https://docs.kernel.org/admin-guide/syscall-user-dispatch.html).

A word on signals, since the chapter leans on them. A **signal** interrupts a thread and runs a handler the program registered. Linux saves the interrupted register state on the thread's stack, in a **signal frame**, runs the handler, and restores the frame when the handler returns. A handler may therefore *edit* the frame, and whatever it writes is what the thread resumes with. That is how a `SIGSYS` handler supplies the result of a system call that never ran.

**ptrace.** The oldest mechanism: a debugger stops the traced process at each call. One variant, `PTRACE_SYSEMU`, stops it and *never runs the call*, leaving the tracer to supply the answer.

**seccomp user notification.** A filter attached to the process can, instead of allowing or denying a call, park the caller and post a message to a **different process**, which answers it. That answering process is a supervisor in user space.

A related but distinct mechanism is a seccomp filter that returns *trap* rather than *notify*, which raises `SIGSYS` in the calling thread itself. That is what [gVisor's current platform, systrap](https://gvisor.dev/docs/architecture_guide/platforms/), uses: a stub handler inside the sandboxed process hands the call to gVisor's kernel through shared memory. It is structurally the same shape as Syscall User Dispatch, and this chapter's chosen path resembles it.

What does **not** exist is an in-kernel version of any of these. All three are driven from user space, and none accepts a callback from a module. The old system-call array is [marked read-only after boot](https://elixir.bootlin.com/linux/v6.12/source/arch/x86/entry/syscall_64.c), is not exported, and on x86-64 is no longer what dispatch reads; nothing in `kernel/entry/common.c` takes a kernel-side handler. Tracing machinery comes closest: a probe on the system-call entry tracepoint runs in the kernel and can even change the call *number*, which is how a call is turned into a failure. It still cannot supply a result, so it cannot service one.

**There is more than one entry point, and this is easy to forget.** `syscall` is how a 64-bit program enters, but a kernel built with 32-bit compatibility — which distribution kernels are — also accepts the legacy software interrupt, the fast 32-bit instruction, and that instruction's emulated form. Four entry functions in all. Anything that claims to intercept a task's system calls must cover every one of them, or it covers none: a program that enters by an unhooked path has its call serviced by Linux, with its own credentials. The patch measured on the [tenant page](tenant.md) hooks one of the four, which that page records as a defect rather than hiding.

## Getting physical memory

Linux's page allocator hands out physically contiguous blocks of 2ⁿ pages, up to a maximum n of [`MAX_PAGE_ORDER`](https://elixir.bootlin.com/linux/v6.12/source/include/linux/mmzone.h#L30), which is 10 — so **4 MiB is the largest block it will give**. A 2 MiB block is one such allocation. Longer runs come from the machinery that backs huge pages, which migrates whatever is in the way; its entry point is exported to modules, though the helper that searches for a suitable range is not. Three properties matter later and are easy to miss. The allocation **may sleep** while it reclaims memory, so it cannot be made from a context that holds a spin lock. Blocks above 32 KiB are what Linux calls [*costly*](https://elixir.bootlin.com/linux/v6.12/source/include/linux/mmzone.h#L46), and a costly allocation is not retried indefinitely and never triggers the out-of-memory killer: under fragmentation it **fails early**, which is the behavior to design for rather than a slow success. And memory taken this way is invisible to Linux's own reclaim, so nothing will take it back under pressure.

## Words used throughout

Four terms come from the rest of the book and are used here without further ceremony.

**Grain**: 2 MiB of physically contiguous memory, the unit in which a kernelet is given memory. A kernelet's **grant** is the set of grains it holds.

**Kind**: one kernelet image. Instances of a kind share their code.

**The kernel proper**: the Asterinas kernel above OSTD — file systems, processes, the network stack — identical in every kernelet, and unchanged by anything in this chapter.

**vOSTD**: the build of OSTD a kernelet is compiled against, which turns machine-level operations into calls on the host ([Terminology](../overview/terminology.md)).

And two Linux terms, to fix the vocabulary:

**Direct map** is Linux's name for what OSTD calls the linear map: all of physical memory, mapped once, in order.

**Module** always means a Linux loadable module. A kernelet is never a module: it is an image the endovisor loads itself, for reasons the [next page](one-address-space.md) gives.
