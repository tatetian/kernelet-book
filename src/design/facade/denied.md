# What the facade does not give a kernelet

A kernelet cannot: disable interrupts (its `LocalIrqDisabled` disables preemption); touch a device register that maps to hardware, except under passthrough; allocate a frame outside its grant; map anything in the kernel half; send an IPI; declare a per-CPU variable; spawn a raw task; queue a closure for the host to run; read the machine's CPU count or memory size; or halt the machine (its `reboot(2)` is `kernelet_exit`). Each of these is a name that does not resolve, and the list is the facade's absence list.
