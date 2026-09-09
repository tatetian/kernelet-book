#!/bin/bash
# fc-snapshot.sh <name> : pause the running microVM <name>, take a full snapshot into snap/<name>.{vmstate,mem},
# count nonzero 4 KiB pages in the memory file, then restore two copies (<name>-r1, <name>-r2) and print
# their Rss / Pss / Shared_Clean / Private_Dirty after 3 s of idle. Run from the directory holding fc-run.sh.
set -e
S=$(dirname "$(readlink -f "$0")"); NAME=$1; FC=$S/release-v1.16.1-x86_64/firecracker-v1.16.1-x86_64
SOCK=/tmp/claude-0/fcrun/$NAME.sock; mkdir -p $S/snap
api() { curl -sS --unix-socket $1 -X $2 "http://localhost$3" -H 'Content-Type: application/json' -d "$4"; }
api $SOCK PATCH /vm '{"state":"Paused"}'
t0=$(date +%s%N); api $SOCK PUT /snapshot/create "{\"snapshot_type\":\"Full\",\"snapshot_path\":\"$S/snap/$NAME.vmstate\",\"mem_file_path\":\"$S/snap/$NAME.mem\"}"; t1=$(date +%s%N)
echo "snapshot create: $(( (t1-t0)/1000000 )) ms"
python3 - "$S/snap/$NAME.mem" <<'PY'
import sys; f=open(sys.argv[1],"rb"); zero=bytes(4096); n=nz=0
while True:
    b=f.read(4096)
    if not b: break
    n+=1; nz+=(b!=zero)
print(f"mem file pages: {n}, nonzero: {nz} ({nz*4/1024:.1f} MiB)")
PY
kill $(cat $S/run/$NAME.pid); sleep 0.5
for R in r1 r2; do N=$NAME-$R; SK=/tmp/claude-0/fcrun/$N.sock; rm -f $SK
  $FC --api-sock $SK --log-path $S/run/$N.log --level Warning >$S/run/$N.console 2>&1 & echo $! > $S/run/$N.pid; sleep 0.3
  t0=$(date +%s%N); api $SK PUT /snapshot/load "{\"snapshot_path\":\"$S/snap/$NAME.vmstate\",\"mem_backend\":{\"backend_path\":\"$S/snap/$NAME.mem\",\"backend_type\":\"File\"},\"resume_vm\":true}"; t1=$(date +%s%N)
  echo "restore $N: $(( (t1-t0)/1000000 )) ms"
done
sleep 3
for R in r1 r2; do echo "== $NAME-$R"; grep -E "^(Rss|Pss|Shared_Clean|Private_Dirty|Anonymous):" /proc/$(cat $S/run/$NAME-$R.pid)/smaps_rollup; done
