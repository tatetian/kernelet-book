#!/bin/bash
# fc-run.sh <name> <mem_mib> <vcpus> [initrd] [balloon] [extra_drive]: boot one microVM (rootfs = ubuntu squashfs, read-only)
# and record host memory before. `balloon` = 1 adds a balloon device with free_page_reporting; `extra_drive` is a second
# read-only image attached as /dev/vdb.
set -e
S=$(dirname "$(readlink -f "$0")"); NAME=$1; MEM=$2; VCPUS=$3; INITRD=$4; BALLOON=$5; EXTRA=$6
FC=$S/release-v1.16.1-x86_64/firecracker-v1.16.1-x86_64
SOCK=/tmp/claude-0/fcrun/$NAME.sock; LOG=$S/run/$NAME.log; mkdir -p $S/run /tmp/claude-0/fcrun; rm -f $SOCK $LOG
grep -E "^(MemFree|PageTables|SecPageTables|KernelStack|Slab|AnonPages|Mapped):" /proc/meminfo > $S/run/$NAME.meminfo.before
$FC --api-sock $SOCK --log-path $LOG --level Warning >$S/run/$NAME.console 2>&1 & FCPID=$!
sleep 0.3
api() { curl -sS --unix-socket $SOCK -X PUT "http://localhost$1" -H 'Content-Type: application/json' -d "$2"; }
BOOT="{\"kernel_image_path\":\"$S/vmlinux-6.1\",\"boot_args\":\"console=ttyS0 reboot=k panic=1 pci=off nomodules random.trust_cpu=on quiet\""
[ -n "$INITRD" ] && BOOT="$BOOT,\"initrd_path\":\"$INITRD\""
api /boot-source "$BOOT}"
api /drives/rootfs "{\"drive_id\":\"rootfs\",\"path_on_host\":\"$S/ubuntu-24.04.squashfs\",\"is_root_device\":false,\"is_read_only\":true}"
[ -n "$EXTRA" ] && api /drives/extra "{\"drive_id\":\"extra\",\"path_on_host\":\"$EXTRA\",\"is_root_device\":false,\"is_read_only\":true}"
api /machine-config "{\"vcpu_count\":$VCPUS,\"mem_size_mib\":$MEM,\"smt\":false}"
[ "$BALLOON" = 1 ] && api /balloon '{"amount_mib":0,"deflate_on_oom":false,"stats_polling_interval_s":1,"free_page_reporting":true}'
api /actions '{"action_type":"InstanceStart"}'
echo $FCPID > $S/run/$NAME.pid; echo "started $NAME pid=$FCPID"
