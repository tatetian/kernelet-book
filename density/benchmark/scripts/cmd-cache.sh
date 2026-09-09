sleep 2
echo MARK0; grep -E "^(MemFree|Cached|AnonPages):" /proc/meminfo; echo ENDMARK0
find /usr/lib /usr/bin /usr/share -type f -print0 2>/dev/null | xargs -0 cat > /dev/null 2>&1
echo MARK1; grep -E "^(MemFree|Cached|AnonPages):" /proc/meminfo; echo ENDMARK1
sleep 100000
