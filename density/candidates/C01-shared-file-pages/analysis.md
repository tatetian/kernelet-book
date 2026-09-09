# C01: Shared file pages

**Status:** adopted. **Depends on kernelets:** yes. **Acts on:** `m_file`, the file data a sandbox has read.

## The problem, measured

A microVM that reads files keeps a private copy of every page it read, in its guest page cache, on top of the copy the host's page cache already holds for the same image file. On this host a 256 MiB Firecracker guest that read the Ubuntu toolchain directories once (205 MiB of files) went from 47 MiB to **245 MiB** of host RSS and stayed there (`../../benchmark/results/firecracker-raw.md`, `cache256`); after a snapshot restore and one work burst a guest held **192 MiB private** of which 168 MiB was page cache (`burst256`). The guest never gives that memory back on its own: with the balloon's free-page reporting enabled the host recovered it only after the *guest* dropped its caches (RSS 245 → 76 MiB within 5 s), which an idle guest does not do, and forcing it means balloon inflation, which Firecracker's documentation calls CPU-intensive. So for an agent sandbox that has done any work, `m_file` is the largest private component, 150–300 MiB, and it is a copy of public, read-only content: the same Python or Node toolchain in every sandbox on the machine.

## The mechanism

A kernelet's window is indexed by physical address and mapped by the host (Blueprint, Memory page, register D58). That makes it possible to hand a kernelet a host page-cache frame *without copying it*: the host maps the frame read-only at `KW_PHYS + paddr` and reports its physical address to the kernelet, and the kernelet's file system uses it as the page for that file offset, mapping it read-only into the tenant's processes for `mmap` and copying from it for `read`. Concretely:

- A new virtual device, the **shared image**, is a read-only file system served by the endovisor from a host directory or image (the `virtiofs` client the kernel proper already has, with a backend whose `read` replies not with bytes but with frame numbers).
- The service half gains one call, `file_page_map(dev, file, offset) -> paddr`, which pins the host page-cache page, maps it read-only into the calling kernelet's window, marks it in the owner array as **borrowed read-only** by that kernelet, and returns its physical address; and `file_page_unmap(paddr)`, the reverse. Borrowed frames are a fourth owner-array state beside free, host and granted.
- Inside the kernelet, vOSTD's page-table code refuses to map a borrowed frame writable in any user page table, and the kernel proper's page cache treats the page as clean and immutable: a write to the file (which the shared image does not allow) or a private mapping of it is served by copying into a granted frame first. The kernel proper needs a `cfg` line in its page-cache `mmap` path for the copy-on-write case; the rest is the `virtiofs` client's existing read-only mode.
- At destroy, the drain list unpins every borrowed frame; a borrowed frame is never zeroed or freed by the kernelet's death, because the host owns it.

This is what `virtiofs` DAX does for a VM by mapping host page cache into guest-physical windows through the EPT (Red Hat's DAX patches report "substantial memory savings" and give the example of a 350 MB `dnf install` costing nothing in the guest). A kernelet needs no EPT and no guest-physical window: the frame's own physical address is its name.

## Gain

After a work burst the baseline VM holds `F` private, 150–300 MiB (default 300). With C01 a kernelet holds **0** private for public file content; the host holds one copy per image per server, amortized over every sandbox using that image, and the frames are ordinary page cache the host can drop under pressure and refault, which no VM's private copy can be. Written files (a tenant's repository, `pip install` output) stay private data in granted frames, as they should: default 20 MiB of the 300, so `m_file` goes from 300 to 20 MiB. Per-sandbox DRAM after one burst, default parameters: baseline 370 MiB → 90 MiB from this candidate alone, a **4.1×** reduction of the warm footprint.

## Evidence

- Measured: 205 MiB read → 198 MiB of additional host RSS (`cache256`), 168 MiB retained as guest page cache after a burst in a 256 MiB guest (`burst256`), the host page cache holding the same squashfs blocks throughout.
- Published: `virtiofs` DAX (LWN, "virtiofs: Add DAX support", 2020) eliminates the guest copy for shared directories; Kata ships it off by default and Firecracker does not implement `virtiofs`.
- Analytic: the gain is exactly `F_public` per sandbox, whatever `F` is.

## Isolation

Within the floor. The shared pages are read-only, of public content (one image), and mapped read-only by the host; a tenant cannot write them, and the isolation the kernel proper's own file system gives between processes of one tenant is unchanged. The residual is the one the floor accepts: cache-timing side channels on shared read-only library pages, the same as between two containers on one Linux host, and the same as `virtiofs` DAX. The kernelet-side rule "never map a borrowed frame writable" is enforced by vOSTD, trusted code, as every other property of the kernelet's own page tables is (Blueprint, Boundaries and trust).

## Cost

- One service call per page-cache page a file system reads for the first time, against one `virtio` request per block today; a `read` of an already-mapped page is a copy inside the kernelet with no crossing.
- Per borrowed frame: one page-table entry in the kernelet's window and one owner-array state; the host page cache's own reference count keeps the frame pinned. A kernelet that borrows 300 MiB holds 75,000 entries in its window and the host's, about 600 KiB of page tables.
- Host page cache pressure is shared: if the host evicts an image page that a kernelet has borrowed, the kernelet's mapping must be revoked first; the simplest rule is that borrowed frames are unevictable while borrowed, which caps the image working set of the machine at the image size, tens of GiB at most.

## Changes to the Blueprint

Recorded here, not applied: a borrowed owner-array state and two service functions (23 functions); a shared-image device model in the endovisor; the `virtiofs` client in the kernel proper wired to it, with one `cfg` line for private mappings; the drain list's unpin step; and a rule on the Memory page that borrowed frames are never granted, freed or zeroed.
