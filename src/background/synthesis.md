# The synthesis in one sentence

> Take Alternative B's *mechanisms* for state, API shape, devices and communication, which are cheaper and more standard than Alternative A's; keep Alternative A's *discipline* for memory, threads, faults and reclamation, which Alternative B does not have; and add one idea neither had, that the page tables which give a kernelet its private data segment can also give it a private heap window, so that a host pointer into a kernelet's memory faults instead of reading when the host is not acting for that kernelet.
