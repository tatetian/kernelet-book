#!/usr/bin/env python3
"""count-nonzero.py <memfile> [--compress]: count nonzero 4 KiB pages of a Firecracker memory file; with --compress, also zlib level 1 per page."""
import sys, zlib
f=open(sys.argv[1],"rb"); zero=bytes(4096); n=nz=raw=comp=0; do=("--compress" in sys.argv)
while True:
    b=f.read(4096)
    if not b: break
    n+=1
    if b!=zero:
        nz+=1
        if do: raw+=4096; comp+=len(zlib.compress(b,1))
print(f"pages {n}, nonzero {nz} ({nz*4/1024:.1f} MiB)" + (f", zlib-1 {comp/2**20:.1f} MiB, ratio {raw/comp:.2f}x" if do else ""))
