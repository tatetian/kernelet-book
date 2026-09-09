sleep 2
python3 -c 'import json,re,os,socket,ssl,http.client,subprocess,asyncio,logging,argparse,pathlib,time,sys; sys.stdout.write("PYREADY\n"); sys.stdout.flush(); time.sleep(100000)' &
sleep 8
echo MARK; head -22 /proc/meminfo; echo ENDMARK
sleep 100000
