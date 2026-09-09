#!/bin/bash
# idle-cpu.sh <name> [seconds]: sum of on-CPU nanoseconds (schedstat field 1) over all threads of the running microVM <name>.
S=$(dirname "$(readlink -f "$0")"); PID=$(cat $S/run/$1.pid); T=${2:-120}
sum() { for t in /proc/$PID/task/*; do awk '{print $1}' $t/schedstat; done | python3 -c "import sys; print(sum(int(l) for l in sys.stdin))"; }
t0=$(sum); sleep $T; t1=$(sum); python3 -c "print(f'$1 idle: {($t1-$t0)/1e6:.1f} ms on-CPU over $T s = {($t1-$t0)/($T*1e9)*100:.3f} % of one core')"
for t in /proc/$PID/task/*; do echo "$(cat $t/comm): $(awk '{print $1/1e6}' $t/schedstat) ms total"; done
