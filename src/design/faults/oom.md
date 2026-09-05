# Out of memory

The [soft band](../memory/bands.md) is `ENOMEM`; the hard band is [T2](tiers.md) at the next quiescent point after a bounded draw from the [death reserve](../memory/bands.md); the kernelet that fails to allocate is always the kernelet that overspent, because the arena is per-kernelet. The remaining obligation, that the arena serves the trip before OSTD's shim sees a null, is a prototype target.
