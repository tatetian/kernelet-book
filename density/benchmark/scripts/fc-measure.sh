#!/bin/bash
# Report the footprint of a running microVM by name.
S=$(dirname "$(readlink -f "$0")"); NAME=$1; PID=$(cat $S/run/$NAME.pid)
echo "== process $PID (firecracker) =="; grep -E "^(Rss|Pss|Shared_Clean|Private_Clean|Private_Dirty|Anonymous|Swap):" /proc/$PID/smaps_rollup
echo "threads: $(ls /proc/$PID/task | wc -l)"; echo "== host kernel memory delta (kB) =="
grep -E "^(PageTables|SecPageTables|KernelStack|Slab|AnonPages|Mapped):" /proc/meminfo > $S/run/$NAME.meminfo.after
join <(sort $S/run/$NAME.meminfo.before) <(sort $S/run/$NAME.meminfo.after) | awk '{printf "%-14s %8d kB\n", $1, $4-$2}'
echo "== guest console tail =="; tail -3 $S/run/$NAME.log 2>/dev/null
