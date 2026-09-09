sleep 2
find /usr/lib /usr/bin /usr/share -type f -print0 2>/dev/null | xargs -0 cat > /dev/null 2>&1
echo MARK1; grep -E "^(MemFree|Cached):" /proc/meminfo; echo ENDMARK1
sleep 15
echo 3 > /proc/sys/vm/drop_caches
echo 1 > /proc/sys/vm/compact_memory
echo MARK2; grep -E "^(MemFree|Cached):" /proc/meminfo; cat /proc/buddyinfo; echo ENDMARK2
sleep 100000
