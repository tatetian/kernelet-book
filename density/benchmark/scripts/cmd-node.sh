sleep 2
ls /dev/vd*; mount -t ext4 -o ro /dev/vdb /root || (dmesg | tail -3; echo MOUNTFAIL)
/root/bin/node -e 'const fs=require("fs"),path=require("path"),http=require("http"),https=require("https"),crypto=require("crypto"),child=require("child_process"),os=require("os"),url=require("url"),zlib=require("zlib"),stream=require("stream"),events=require("events"); console.log("NODEREADY"); setInterval(()=>{},60000);' &
sleep 10
echo MARK; grep -E "^(MemTotal|MemFree|Cached|AnonPages):" /proc/meminfo; echo ENDMARK
sleep 100000
