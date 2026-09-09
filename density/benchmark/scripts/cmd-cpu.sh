sleep 2
echo CPUBENCH_START
python3 - <<'PY'
import mmap, time, os, subprocess
# 1. first-touch page faults: 192 MiB of fresh anonymous memory
n=192*1024*1024; t=time.perf_counter(); m=mmap.mmap(-1,n)
for i in range(0,n,4096): m[i]=1
t=time.perf_counter()-t; print(f"PF first-touch: {n//4096} pages in {t*1000:.0f} ms = {t/(n//4096)*1e6:.2f} us/page"); m.close()
# 2. re-touch after munmap of a second region twice (warm faults of already-backed guest memory)
m=mmap.mmap(-1,n)
for i in range(0,n,4096): m[i]=1
m.close(); t=time.perf_counter(); m=mmap.mmap(-1,n)
for i in range(0,n,4096): m[i]=1
t=time.perf_counter()-t; print(f"PF second pass (memory already touched once by the guest): {t/(n//4096)*1e6:.2f} us/page"); m.close()
# 3. fork+exec
t=time.perf_counter()
for i in range(300): subprocess.run(["/bin/true"])
t=time.perf_counter()-t; print(f"fork+exec /bin/true: {t/300*1000:.2f} ms each")
# 4. syscall loop
t=time.perf_counter()
for i in range(200000): os.getpid()
t=time.perf_counter()-t; print(f"getpid: {t/200000*1e9:.0f} ns each")
PY
echo CPUBENCH_END
sleep 100000
