# Firecracker baseline: raw host-side measurements (2026-09-09)
host: 8-core Xeon E3-1270 v6, 31 GB, Linux 6.8.0-100, Firecracker v1.16.1, guest vmlinux 6.1.128 (Firecracker CI config), rootfs ubuntu-24.04.squashfs (CI), read-only

## idle128: 1 vCPU, 128 MiB, init = sleep (busybox initramfs, squashfs root)
Rss 47192 kB; Anonymous 44688 kB; threads 4; host delta: SecPageTables +120 kB, PageTables +108 kB, Mapped +2504 kB
snapshot: create 476 ms; mem file 128 MiB with 8546 nonzero pages = 33.4 MiB; vmstate 13.8 KB; restore 35-36 ms
two restores from one snapshot, idle: Rss 9956/10140 kB, Pss 6220/6404 kB, Shared_Clean 7460 kB, Private_Dirty 864 kB each

## py256: 1 vCPU, 256 MiB, python3 resident with json,re,os,socket,ssl,http.client,subprocess,asyncio,logging,argparse,pathlib imported
guest: MemTotal 238296 kB, MemFree 187844 kB, Cached 23720 kB, AnonPages 12312 kB
host: Rss 73052 kB, Anonymous 70628 kB
snapshot: create 967 ms; 15260 nonzero pages = 59.6 MiB; restore 18-36 ms; two restores idle: Rss 10020 kB, Pss 5438 kB, Shared_Clean 9152 kB, Private_Dirty 860 kB; after 25 s idle Private_Dirty 888 kB

## cache256: 1 vCPU, 256 MiB, guest reads every file under /usr/lib /usr/bin /usr/share once
guest: Cached 204-211 MB, MemFree 5-8 MB; host: Rss 250604-251116 kB (RssAnon 248196 kB) and stays; guest region 262144 kB with Rss 247928 kB

## fpr: same read, balloon with free_page_reporting=true (Linux 6.1 guest reports free blocks of order >= 9)
after read: Rss 249672-251488 kB; in-guest sha256 of python3.12, libc, libcrypto identical before and after (data intact); snapshot nonzero 56877 pages = 222.2 MiB
after 'echo 3 > drop_caches; echo 1 > compact_memory': guest MemFree 213708 kB; host Rss 77620 kB within 5 s and stable at 15 s and 30 s

## burst256: python resident, snapshot at t=12 s, two restores, then each guest reads /usr/lib/python3.12 /usr/bin /usr/lib/x86_64-linux-gnu and allocates+touches 30 MiB
right after restore (idle): Rss 9836 kB, Pss 5868 kB, Shared_Clean 7924 kB, Private_Dirty 848 kB
after the burst: Rss 226376 kB, Pss 210092 kB, Shared_Clean 32556 kB, Private_Dirty 191884 kB (b2: 191956 kB); guest MemFree 5364 kB, Cached 168312 kB, AnonPages 45948 kB (the 256 MiB guest trimmed its cache to fit)

## idle CPU: restored idle 128 MiB VM, 60 s: 2 ticks of utime+stime = 0.03 % of one core
## compressibility: nonzero pages of the py256 snapshot (kernel + resident Python, before any burst): 59.6 MiB raw -> 22.5 MiB with per-page zlib level 1, ratio 2.64x
## this host's cold read rate, 64 MiB O_DIRECT from the snapshot file: 185 MB/s (a slow disk; the model server assumes NVMe at 2-3 GB/s, per REAP's 850 MB/s on SATA with concurrent 16 KiB reads)

## node256: 1 vCPU, 256 MiB, Node.js v22.12.0 (official linux-x64 binary on an attached read-only ext4 image, mounted at /root) resident with fs, path, http, https, crypto, child_process, os, url, zlib, stream, events required and a timer keeping it alive
guest: MemFree 161692 kB, Cached 52500 kB, AnonPages 8400 kB; host: Rss 101264 kB, Anonymous 98896 kB
snapshot: create 890 ms; 22357 nonzero pages = 87.3 MiB; restore 11-32 ms; two restores idle: Pss 5828/5900 kB, Shared_Clean 8444 kB, Private_Dirty 884 kB
note: the node binary is 118 MB and its mapped text is guest page cache (the 52.5 MiB Cached), public content; the idle heap is the 8.4 MiB anonymous

## fpr4: as fpr but with page_reporting.page_reporting_order=4: after read Rss 249736 kB; 15 s after drop_caches+compact_memory Rss 78224 kB (order 9 gave 77620 kB): the residue does not depend on the reporting order
## node256b idle CPU (schedstat, all threads, 120 s): 39.3 ms on-CPU = 0.033 % of one core (fc_vcpu 0 thread 191.5 ms total since boot, most of it the boot); host kvm halt_poll_ns = 200000
## cpu512: microbenchmarks inside a 1 vCPU 512 MiB guest vs the same script on the host (Python 3.12 both):
guest: first-touch page faults 4.43 us/page (49152 pages, 218 ms); second pass over guest-touched memory 1.88 us/page; fork+exec /bin/true 0.44 ms; getpid 627 ns
host:  first-touch 2.06 us/page (101 ms); second pass 1.99 us/page; fork+exec 0.62 ms (host disk is overlayfs, not comparable); getpid 626 ns
## virtio-pmem DAX: Firecracker 1.16 has the /pmem API (pmem.md reports a 128 MB VM at ~96 MB RSS with DAX against ~120 MB without), but the CI guest kernel vmlinux-6.1.128 has no CONFIG_VIRTIO_PMEM / FS_DAX, so the DAX variant of cache256 could not be run here
