# Scripts

All scripts expect to sit beside the Firecracker release directory (`release-v1.16.1-x86_64/`), the guest kernel `vmlinux-6.1` (Firecracker CI `vmlinux-6.1.128`), the root image `ubuntu-24.04.squashfs` (Firecracker CI) and a static `busybox`; see `../README.md` §4 and §6 for where they come from. Nothing here runs more than two microVMs at a time.

- `mkinitrd.sh <name> <command-or-file>`: builds `run/<name>.cpio`, an initramfs whose `init` mounts the squashfs root and runs the command inside it via busybox `chroot`.
- `fc-run.sh <name> <mem_mib> <vcpus> [initrd]`: boots one microVM through the Firecracker API and records `/proc/meminfo` before.
- `fc-measure.sh <name>`: prints the Firecracker process's `smaps_rollup` and the `/proc/meminfo` deltas.
- `fc-snapshot.sh <name>`: pauses, snapshots, counts nonzero pages, restores two copies and prints their shared and private memory.
- `cmd-*.sh`: the guest-side command files used for the results (`py` resident Python, `cache` toolchain read, `reclaim` read then drop caches with free-page reporting, `integrity` hashes before and after the read, `burst` the post-restore work burst).
