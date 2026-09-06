# Boot, power, panic, and the rest

*Part of question 2. Virtualizes `boot`, `smp`, `power`, `console`, `log`, `panic`, the `#[ostd::main]` expansion, and the `arch` surface. Discharges invariant I8's obligation to list every tenant-visible difference.*

## Boot

A kernelet is not booted; it is entered. `_kernelet_entry` runs on the boot task with the window populated, and OSTD (kernelet build)'s initialization is the host build's with everything the machine did already removed: no early allocator, no serial port, no CPU feature enabling, no kernel page table construction, no `smp::init`, no boot page table to dismiss (checked on the tree: `ostd/src/lib.rs`, `init`). The boot task is pinned to virtual CPU 0, since `main` initializes the boot CPU's per-CPU state and pins its idle loop there. What remains, in order: store the service table pointer and read `BootArgs`; read the host-written grant table, lay out the initial runs' metadata and hand them to the frame allocator ([Memory](memory.md)); set up the per-virtual-CPU replicas and mark virtual CPU 0 current; initialize the kernelet-side task and body tables and register the boot task as name 0; run the image's `.init_array`, which is how components register themselves, as on the host; and call `__ostd_main`, which is the kernel proper's `main`.

`boot::boot_info` is virtualized without a crossing: a `BootInfo` synthesized from `BootArgs` with the bootloader name `"kernelet"`, the command line, `memory_regions` holding one `Usable` region per initial grain, and no ACPI, framebuffer or initramfs arguments. The kernel proper reads the command line through the identical `#[ostd::early_cmdline_parser]` and `EarlyCmdline`. An initial RAM file system, if the endovisor provides one, arrives as a block device, not as a boot module. `MemoryRegion`, `MemoryRegionType` and `EarlyCmdline` are identical types.

`boot::smp::register_ap_entry(entry)` is virtualized: the host kernel runs the entry once on each application processor after boot (checked on the tree: `kernel/core/src/init.rs`, `ap_init`), and the kernelet build runs it once on each virtual CPU above 0, on a task it spawns pinned to that virtual CPU with `SPAWN_IDLE` cleared, during `_kernelet_entry` after `main` has registered the entry. The kernel proper's `init_on_each_cpu` and its per-CPU idle thread therefore run on every virtual CPU as they do on every real one, and the idle threads park through the virtualized `halt_cpu` ([Tasks](tasks.md)). `smp::inter_processor_call` is absent.

**The end of `main`.** `#[ostd::main]` expands to a function that calls the kernel's `main`, yields, asserts that there is no current task, and powers off (checked on the tree: `ostd/libs/ostd-macros`, `ostd_main_body`); that assertion holds on the host because the host's `main` runs in the bootstrap context, not on a task. Inside a kernelet `main` runs on the boot task, so the expansion is virtualized under the feature: after `main` returns, the boot task parks forever with `task_park`, and the kernelet lives on in the tasks `main` spawned. The `#[ostd::main]` attribute the kernel proper writes is unchanged.

## Power and exit

`power::poweroff(code)` and `power::restart(code)` are virtualized to the `exit` service call, with `ExitCode::Success` mapped to `0` and `Failure` to `1`; a new `power::exit_with_code(u32)`, present in both builds and `poweroff` in the host build, carries an arbitrary code. `inject_poweroff_handler` and `inject_restart_handler` are accepted and never called, since the ACPI paths they install are host-only and `cfg`'d out of the kernel proper's `arch/x86/power.rs` in the kernelet build. The kernel proper's `reboot(2)` therefore ends the kernelet with code 0, since the syscall passes `Success` (checked on the tree: `syscall/reboot.rs`), and its init-exit path, which on the host kernel panics with the init process's status (checked: `kernel/core/src/init.rs`, `bsp_idle_loop`), gets the one `cfg` line the [taxonomy](index.md) lists, calling `exit_with_code(status)` so that init exiting ends the kernelet as `Exited(status)` rather than `Panicked`. The kernelet runtime reads the code through the [endovisor ABI](../endovisor.md).

## Panic, oops, and the unwinder

`catch_unwind`, `begin_panic` and `print_stack_trace` are identical: the unwinder and its tables are in the kernelet image, and the image's linker script provides the symbols it needs ([Builds and images](../builds-and-images.md)). The kernel proper's `#[ostd::panic_handler]`, its oops mechanism, is identical too: a panic on a user task unwinds to the task's catch, the oops counter is charged, and the thread dies while the kernelet continues (checked on the tree: `kernel/core/src/thread/oops.rs`). Two things are virtualized beneath it, both in the expansion of the attribute under the feature, which wraps the kernel's handler so that the panic message is captured. First, each caught panic is reported to the host with the `oops` service call, so that the endovisor's oops budget counts it and can end a kernelet that oopses without limit; the kernel proper's own `MAX_OOPS_COUNT` applies as well and is the lower of the two in practice. Second, `panic::abort`, which the oops handler calls when it decides the panic is not recoverable, and which on the host kernel powers the machine off, is the `panic` service call, with the captured message: it ends the kernelet as `Panicked(message)` and only the kernelet. `__ostd_panic_handler` itself, the fallback when no handler is injected, does the same through the same call. `print_stack_trace` writes through `console_write`.

An allocation failure the kernel cannot absorb reaches `#[alloc_error_handler]`, which in the kernelet build is the `panic` service with "out of memory" ([Memory](memory.md)).

## Console and log

`early_print!` and `early_println!` are virtualized to `console_write`; they are the kernel proper's boot-time and panic-time output, and the endovisor's `console_write` hook delivers them to wherever the runtime attached the console. The log macros are virtualized at their sink: formatting, the per-crate prefix and level filtering are identical, and `__write_log_record` delivers the formatted record to the injected `Log` if there is one and otherwise to the `log_write` service call. The kernel proper's `logger` component, which writes to the serial port, is host-only, so no logger is injected in a kernelet and every record goes to `log_write`, rate-limited per the kernelet's policy and delivered to the endovisor's `log` hook. `set_max_level` and `max_level` are identical. A tenant's `dmesg` inside the kernelet is whatever the kernel proper keeps in its own ring buffer, as on the host; the host sees the records the hook received.

## `arch`, `bus`, `util`, `prelude`

`read_tsc`, `read_random` and `cpuid` are identical: unprivileged or ring-0 instructions with local effect. `tsc_freq` is virtualized to read `BootArgs::tsc_freq_hz`, since the host calibrated it. `TrapFrame`, `USER_CS_VALUE` and `USER_SS_VALUE` are identical. `IRQ_CHIP`, `MappedIrqLine`, `ACPI_INFO`, `DEVICE_TREE`, `SERIAL_PORT` and the port I/O types are absent; their users are the host-only components and the MMIO bus's interrupt step, which has its `cfg` line ([Devices](devices.md)). `bus::BusProbeError`, everything in `util`, the `prelude`, `Error` and `Result` are identical.

## `ktest`

The kernel's unit tests run inside a kernel; a test of the kernel proper in its kernelet configuration must run inside a kernelet. `#[ktest]` and `.ktest_array` are identical, and the harness is the endovisor's: a test kind of kernelet image whose `main` runs the test array, created by a host-side test runner through the control half, with its log routed to the runner and its exit code the verdict. That is an Implementation-chapter matter; the design's requirement is only that nothing on this page prevents it, and nothing does.

## What a tenant sees

- `/proc/cmdline` is the configured command line; `/proc/meminfo`'s total is the initial grant; there are no ACPI tables, no framebuffer, no serial ports.
- `reboot(2)` ends the sandbox with a code the runtime sees; `init` exiting ends it with init's status.
- A kernel panic ends the sandbox, not the machine; a kernel oops kills the thread and continues, as on the host kernel, up to a budget the runtime sets.
- Kernel log records reach the host's log hook rather than a serial port; the kernelet's own `dmesg` is unchanged.
- `nproc` is the virtual-CPU count; the TSC frequency is the host's.

## Costs

- Entry: a few microseconds of initialization on the boot task (*estimated*); the grain mapping and replica setup dominate.
- Per log record: one crossing, a copy of up to 1 KiB, and the hook, when under the rate limit; a dropped record costs the crossing and a counter.
- Per oops: one crossing and the hook, in addition to the unwinding the host kernel pays today.

## What this page decides

- **`main` runs on the boot task and parks when it returns** (register D26); the alternative, ending the kernelet when `main` returns, would end it before its init process runs, since the kernel proper's `main` returns after spawning the first kernel thread (checked on the tree: `kernel/core/src/init.rs`).
- **Init exiting ends the kernelet as an exit, not a panic** (register D27), by one `cfg` line in the kernel proper; without it the runtime could not tell a clean shutdown from a crash.
- **Every caught panic is reported to the host** (register D28), so that an oops budget can be a host policy rather than only the kernel proper's own constant.
