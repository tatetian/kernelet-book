sleep 2
python3 -c 'import json,re,os,socket,ssl,http.client,subprocess,asyncio,logging,argparse,pathlib,time,sys; sys.stdout.write("PYREADY\n"); sys.stdout.flush(); time.sleep(100000)' &
sleep 30
echo BURST_START
find /usr/lib/python3.12 /usr/bin /usr/lib/x86_64-linux-gnu -type f -print0 2>/dev/null | xargs -0 cat > /dev/null 2>&1
python3 -c 'import time; b=bytearray(30*1024*1024); 
for i in range(0,len(b),4096): b[i]=1
time.sleep(100000)' &
sleep 5
echo BURST_END; grep -E "^(MemFree|Cached|AnonPages):" /proc/meminfo
sleep 100000
