#!/bin/bash
# fetch-assets.sh: downloads the pinned artifacts the scripts expect, into the current directory.
set -e
FC_VER=v1.16.1; CI=firecracker-ci/v1.12/x86_64
curl -sSL -o fc.tgz https://github.com/firecracker-microvm/firecracker/releases/download/$FC_VER/firecracker-$FC_VER-x86_64.tgz && tar xzf fc.tgz
curl -sSL -o vmlinux-6.1 http://spec.ccfc.min.s3.amazonaws.com/$CI/vmlinux-6.1.128
curl -sSL -o ubuntu-24.04.squashfs http://spec.ccfc.min.s3.amazonaws.com/$CI/ubuntu-24.04.squashfs
curl -sSL -o ubuntu-24.04.manifest http://spec.ccfc.min.s3.amazonaws.com/$CI/ubuntu-24.04.manifest
curl -sSL -o busybox https://busybox.net/downloads/binaries/1.35.0-x86_64-linux-musl/busybox && chmod +x busybox
# optional, for the Node.js measurement: node-v22.12.0-linux-x64 from nodejs.org, its bin/node copied onto a 160 MiB ext4 image
sha256sum fc.tgz vmlinux-6.1 ubuntu-24.04.squashfs busybox | tee ASSETS.sha256
