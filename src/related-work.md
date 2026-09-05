# Related Work

> **To be written.** Each section below is a placeholder naming the systems the design is compared with or borrows from; the comparison itself has not been written yet. Nothing here should be read as a claim.

## Containers and sandboxed containers

> Docker, seccomp and AppArmor; gVisor (a user-space kernel behind syscall interception); Kata Containers. The trilemma in [Background](executive-summary.md#industry) is the frame: what each gives up.

## MicroVMs

> Firecracker and Cloud Hypervisor: hardware isolation at the price of a second translation layer, VM exits and a guest kernel per sandbox. What this design keeps from the microVM world: virtio as the device surface, vsock as the channel, and the hypervisor as the reference point for the endovisor.

## Language-based and type-based isolation in kernels

> SPIN, Singularity, Theseus, RedLeaf: what this design takes (RedLeaf's exchangeable-type rule for what may cross a boundary, Theseus's intralingual state, Singularity's exchange heap) and where it differs (a Linux-compatible kernel, page-table windows as a backstop).

## Intra-kernel isolation and hardware backstops

> Nooks, LXFI, ERIM and Hodor, Intel PKS: software and hardware compartments inside one kernel, and why this design uses page tables rather than protection keys.

## Capability systems

> seL4 and Zircon: handles, unforgeable references and the resolver's checks.

## Unikernels and library operating systems

> Unikernels and Occlum: one application per kernel image, and what a kernelet shares with and takes from them.

## WebAssembly sandboxes

> Runtime validation without a kernel; the Linux-ABI gap.
