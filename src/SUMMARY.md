# Summary

[Executive Summary](executive-summary.md)

# The Paper

- [Abstract](paper/abstract.md)
- [Introduction](paper/introduction.md)
- [Background and Motivation](paper/background.md)
- [API Virtualization](paper/api-virtualization.md)
- [Design](paper/design.md)
- [Implementation](paper/implementation.md)
- [Evaluation](paper/evaluation.md)
- [Related Work](paper/related-work.md)
- [References](paper/references.md)

# The Blueprint

- [The Blueprint](blueprint/index.md)
- [Overview](blueprint/overview/index.md)
  - [Goals: what the boundary owes](blueprint/overview/goals.md)
  - [API virtualization, in one page](blueprint/overview/api-virtualization.md)
  - [Terminology](blueprint/overview/terminology.md)
  - [Why it is hard](blueprint/overview/challenges.md)
- [Design](blueprint/design/index.md)
  - [Boundaries and trust](blueprint/design/principles.md)
  - [Builds and images](blueprint/design/builds-and-images.md)
  - [The kernelet API: control half](blueprint/design/kernelet-api-control.md)
  - [The kernelet API: service half](blueprint/design/kernelet-api-service.md)
  - [Virtualizing OSTD](blueprint/design/virtualizing-ostd/index.md)
    - [Memory](blueprint/design/virtualizing-ostd/memory.md)
    - [Tasks, scheduling, and CPUs](blueprint/design/virtualizing-ostd/tasks.md)
    - [Interrupts and time](blueprint/design/virtualizing-ostd/interrupts-and-time.md)
    - [User mode](blueprint/design/virtualizing-ostd/user-mode.md)
    - [Devices](blueprint/design/virtualizing-ostd/devices.md)
    - [Boot, power, panic, and the rest](blueprint/design/virtualizing-ostd/the-rest.md)
  - [Faults, termination, and reclamation](blueprint/design/faults-and-reclamation.md)
  - [Channels](blueprint/design/channels.md)
  - [Zero-copy I/O](blueprint/design/zero-copy-io.md)
  - [The endovisor](blueprint/design/endovisor.md)
  - [The kernelet runtime](blueprint/design/kernelet-runtime.md)
- [Linux as the host](blueprint/linux-mode/index.md)
  - [Background: the Linux this chapter needs](blueprint/linux-mode/background.md)
  - [One address space, many kernelets](blueprint/linux-mode/one-address-space.md)
  - [The endovisor as a Linux module](blueprint/linux-mode/endovisor.md)
  - [The tenant: user mode and system calls](blueprint/linux-mode/tenant.md)
  - [Five places where Linux does not behave as the design assumed](blueprint/linux-mode/not-as-assumed.md)
  - [What differs between the two hosts](blueprint/linux-mode/what-differs.md)
  - [Evidence](blueprint/linux-mode/evidence.md)

# The Notes

- [The Notes](notes/index.md)
- [OSTD API inventory](notes/ostd-api-inventory.md)
- [I/O microbenchmarks](notes/io-microbenchmarks.md)
- [Linux-mode experiments](notes/linux-mode-experiments.md)
- [Design register](notes/design-register.md)
