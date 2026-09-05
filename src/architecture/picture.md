# The picture

```mermaid
flowchart TB
    subgraph shared["Shared by every kernelet (TCB): mapped in every page table"]
        ostd["<b>ostd</b>"]
        hk["<b>endovisor</b><br/>backends · scheduler · allocators<br/>handle tables · RRef table · kill/reclaim"]
        abi["<b>kernelet-abi</b> (the facade)<br/>OSTD's module tree: re-exports + virtualized items"]
        text["<b>aster-kernelet .text/.rodata</b><br/>the kernel, compiled once"]
    end
    subgraph kerneletA["Kernelet A's page tables only"]
        dataA["data window: A's .data/.bss"]
        heapA["heap window: A's arena"]
        userA["A's user half"]
    end
    subgraph kerneletB["Kernelet B's page tables only"]
        dataB["data window: B's .data/.bss"]
        heapB["heap window: B's arena"]
        userB["B's user half"]
    end
    subgraph hostpt["The host's own page table (host tasks in thread context)"]
        nowin["entry 500: nothing"]
    end
    hk -- "implements" --> abi
    hk -- "depends on" --> ostd
    abi -- "depends on" --> ostd
    text -- "depends on (under the name `ostd`)" --> abi
    text -. "same virtual addresses" .-> dataA
    text -. "same virtual addresses" .-> dataB
```

Two things are absent from the picture on purpose. There is no edge from `aster-kernelet` to `ostd` or `endovisor`: the kernelet crate cannot name them. And there is no window in the host's own page table, and no kernelet's page tables map another kernelet's windows.
