sleep 2
echo SHA_BEFORE; sha256sum /usr/bin/python3.12 /usr/lib/x86_64-linux-gnu/libc.so.6 /usr/lib/x86_64-linux-gnu/libcrypto.so.3
find /usr/lib /usr/bin /usr/share -type f -print0 2>/dev/null | xargs -0 cat > /dev/null 2>&1
echo MARK1; grep -E "^(MemFree|Cached):" /proc/meminfo; echo ENDMARK1
sleep 20
echo SHA_AFTER; sha256sum /usr/bin/python3.12 /usr/lib/x86_64-linux-gnu/libc.so.6 /usr/lib/x86_64-linux-gnu/libcrypto.so.3
echo DONE
sleep 100000
