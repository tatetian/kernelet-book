# Executive Summary

This book is written for two kinds of reader, and it tries to serve both without shortchanging either.

**Asterinas developers** will build this. For them the book is a specification: [The Blueprint](blueprint/index.md), whose chapters will say what runs where, fix every layer down to the types and the checks, and list the OSTD changes, the enforcement checks and the staged plan in the order they should be done. It is meant to be precise enough that a coding agent can work from it; its Overview and its Design chapter are written, and the implementation plan, the evaluation plan and the limitations are still to come.

**Academic readers** will judge it. For them the book is the long form of a paper: the motivation and the isolation trilemma below, the earlier prototype it grew out of, the mechanisms and their costs, an honest account of where the design loses and of what has not been verified, and the [prior art](paper/related-work.md) it is compared with.

The two pitches below are the same idea told to each audience.

## The pitch to industry {#industry}

> **Give every agent its own kernel.**

**Agents are multiplying. Every one of them needs its own computer, one it cannot escape.**

Agents install dependencies, run tests, compile code, drive browsers. They don't need a function runtime; they need a full Linux machine that can be torn down and rebuilt at will. Sandboxing has gone from an ops option to a primitive of AI infrastructure, and every sandbox available today is either not fast enough or not strong enough.

A kernelet is a complete, Linux-compatible kernel light-weight enough to give one to every agent. Asterinas runs many kernelets side by side inside a single host kernel, each written in safe Rust and each serving one tenant, so unmodified Linux applications get a kernel of their own. VMs pay a price for hardware isolation; kernelets don't. Containers share a kernel; kernelets don't.

<figure class="fwd-fig">
<div class="head">
<div class="tag">Three ways to give an agent a computer</div>
<div class="title">Kernelets: speed of containers, security of microVMs</div>
</div>
<div class="cmp">
<div class="col">
<div class="tag">Option A</div>
<div class="name">Containers</div>
<svg viewBox="0 0 300 190" role="img" aria-label="Containers share one Linux kernel">
<g font-family="ui-monospace,monospace" font-size="10.5">
<rect x="14" y="12" width="80" height="40" rx="6" fill="rgba(255,255,255,.06)" stroke="rgba(255,255,255,.16)"/>
<rect x="110" y="12" width="80" height="40" rx="6" fill="rgba(255,255,255,.06)" stroke="rgba(255,255,255,.16)"/>
<rect x="206" y="12" width="80" height="40" rx="6" fill="rgba(255,255,255,.06)" stroke="rgba(255,255,255,.16)"/>
<text x="54" y="36" fill="#9AA0BE" text-anchor="middle">agent A</text>
<text x="150" y="36" fill="#9AA0BE" text-anchor="middle">agent B</text>
<text x="246" y="36" fill="#9AA0BE" text-anchor="middle">agent C</text>
<path d="M54 52 v22 M150 52 v22 M246 52 v22" stroke="#FF5C7A" stroke-width="1.4" stroke-dasharray="3 3"/>
<rect x="14" y="76" width="272" height="70" rx="8" fill="rgba(255,92,122,.10)" stroke="rgba(255,92,122,.45)"/>
<text x="150" y="105" fill="#FF8FA3" text-anchor="middle" font-size="12">ONE SHARED LINUX KERNEL</text>
<text x="150" y="124" fill="#8A6070" text-anchor="middle" font-size="9.5">~30M LoC of C · full syscall surface</text>
<rect x="14" y="156" width="272" height="24" rx="5" fill="rgba(255,255,255,.03)" stroke="rgba(255,255,255,.12)"/>
<text x="150" y="172" fill="#6A6F8C" text-anchor="middle" font-size="9.5">hardware</text>
</g>
</svg>
</div>
<div class="col">
<div class="tag">Option B</div>
<div class="name">microVMs</div>
<svg viewBox="0 0 300 190" role="img" aria-label="microVMs stack a second kernel behind hardware nesting">
<g font-family="ui-monospace,monospace" font-size="10.5">
<rect x="14" y="12" width="80" height="26" rx="5" fill="rgba(255,255,255,.06)" stroke="rgba(255,255,255,.16)"/>
<rect x="110" y="12" width="80" height="26" rx="5" fill="rgba(255,255,255,.06)" stroke="rgba(255,255,255,.16)"/>
<rect x="206" y="12" width="80" height="26" rx="5" fill="rgba(255,255,255,.06)" stroke="rgba(255,255,255,.16)"/>
<text x="54" y="29" fill="#9AA0BE" text-anchor="middle">agent A</text>
<text x="150" y="29" fill="#9AA0BE" text-anchor="middle">agent B</text>
<text x="246" y="29" fill="#9AA0BE" text-anchor="middle">agent C</text>
<rect x="14" y="44" width="80" height="26" rx="5" fill="rgba(127,129,140,.14)" stroke="rgba(255,255,255,.2)"/>
<rect x="110" y="44" width="80" height="26" rx="5" fill="rgba(127,129,140,.14)" stroke="rgba(255,255,255,.2)"/>
<rect x="206" y="44" width="80" height="26" rx="5" fill="rgba(127,129,140,.14)" stroke="rgba(255,255,255,.2)"/>
<text x="54" y="61" fill="#B9BED8" text-anchor="middle">guest krnl</text>
<text x="150" y="61" fill="#B9BED8" text-anchor="middle">guest krnl</text>
<text x="246" y="61" fill="#B9BED8" text-anchor="middle">guest krnl</text>
<rect x="14" y="80" width="272" height="22" rx="4" fill="rgba(255,176,32,.12)" stroke="rgba(255,176,32,.5)"/>
<text x="150" y="95" fill="#FFC65C" text-anchor="middle" font-size="10">EPT · VM EXIT · vCPU SCHEDULING</text>
<rect x="14" y="110" width="272" height="36" rx="7" fill="rgba(255,255,255,.05)" stroke="rgba(255,255,255,.16)"/>
<text x="150" y="133" fill="#9AA0BE" text-anchor="middle">host kernel + VMM</text>
<rect x="14" y="156" width="272" height="24" rx="5" fill="rgba(255,255,255,.03)" stroke="rgba(255,255,255,.12)"/>
<text x="150" y="172" fill="#6A6F8C" text-anchor="middle" font-size="9.5">hardware</text>
</g>
</svg>
</div>
<div class="col win">
<div class="tag">Option C</div>
<div class="name">Asterinas Kernelets</div>
<svg viewBox="0 0 300 190" role="img" aria-label="kernelets put safe-Rust kernel instances side by side over a small sound core">
<defs>
<linearGradient id="fwd-cg" x1="0" y1="0" x2="1" y2="0">
<stop offset="0%" stop-color="#00F7FF" stop-opacity=".22"/>
<stop offset="100%" stop-color="#1937FF" stop-opacity=".22"/>
</linearGradient>
</defs>
<g font-family="ui-monospace,monospace" font-size="10.5">
<rect x="14" y="12" width="80" height="26" rx="5" fill="rgba(255,255,255,.06)" stroke="rgba(255,255,255,.16)"/>
<rect x="110" y="12" width="80" height="26" rx="5" fill="rgba(255,255,255,.06)" stroke="rgba(255,255,255,.16)"/>
<rect x="206" y="12" width="80" height="26" rx="5" fill="rgba(255,255,255,.06)" stroke="rgba(255,255,255,.16)"/>
<text x="54" y="29" fill="#9AA0BE" text-anchor="middle">agent A</text>
<text x="150" y="29" fill="#9AA0BE" text-anchor="middle">agent B</text>
<text x="246" y="29" fill="#9AA0BE" text-anchor="middle">agent C</text>
<rect x="14" y="46" width="80" height="52" rx="6" fill="url(#fwd-cg)" stroke="rgba(0,247,255,.55)"/>
<rect x="110" y="46" width="80" height="52" rx="6" fill="url(#fwd-cg)" stroke="rgba(0,247,255,.55)"/>
<rect x="206" y="46" width="80" height="52" rx="6" fill="url(#fwd-cg)" stroke="rgba(0,247,255,.55)"/>
<text x="54" y="70" fill="#8FF6FC" text-anchor="middle">Kernelet A</text>
<text x="150" y="70" fill="#8FF6FC" text-anchor="middle">Kernelet B</text>
<text x="246" y="70" fill="#8FF6FC" text-anchor="middle">Kernelet C</text>
<text x="54" y="87" fill="#5C93A8" text-anchor="middle" font-size="8.5">safe Rust</text>
<text x="150" y="87" fill="#5C93A8" text-anchor="middle" font-size="8.5">safe Rust</text>
<text x="246" y="87" fill="#5C93A8" text-anchor="middle" font-size="8.5">safe Rust</text>
<rect x="14" y="108" width="272" height="24" rx="5" fill="rgba(25,55,255,.22)" stroke="rgba(0,247,255,.5)"/>
<text x="150" y="124" fill="#00F7FF" text-anchor="middle" font-size="10">OSTD: small, sound, partly proven</text>
<text x="150" y="150" fill="#4C5170" text-anchor="middle" font-size="9">no hypervisor · no EPT · no VM exit</text>
<rect x="14" y="156" width="272" height="24" rx="5" fill="rgba(255,255,255,.03)" stroke="rgba(255,255,255,.12)"/>
<text x="150" y="172" fill="#6A6F8C" text-anchor="middle" font-size="9.5">hardware</text>
</g>
</svg>
</div>
</div>
</figure>

## The pitch to academia {#academia}

> **API virtualization: a third way between machine virtualization and OS virtualization.**

Two ways of multiplexing a machine among mutually distrusting tenants have dominated for twenty years. **Machine virtualization** runs an unmodified guest kernel on virtual hardware; the boundary is the hardware's, strong and well understood, and the price is a second layer of address translation, VM exits, a device model, and a whole guest kernel's memory and scheduler per tenant. **OS virtualization** multiplexes one kernel through namespaces and control groups; the price is near zero, and the boundary is the correctness of thirty million lines of C that every tenant can drive through the full syscall table.

Asterinas Kernelets are a third point in that space, and this book calls the idea **API virtualization**: rather than virtualizing the hardware beneath a kernel, or multiplexing one kernel above its syscall table, it virtualizes the interface a kernel is written against, so that each tenant gets a kernel of its own and the machine underneath stays real. The Asterinas kernel is a *framekernel*: all `unsafe` code lives in a small framework, OSTD, and the roughly 180,000 lines of kernel above it are safe Rust written against OSTD's API. That API is the thing to virtualize. A **kernelet** is the unmodified kernel compiled against **vOSTD**, virtual OSTD: OSTD's own source built a second time under a `kernelet` feature, which keeps every item whose effect is local to the caller, re-implements the items that touch machine-wide state over a small **kernelet API** that the host's OSTD exposes, and omits what a kernelet must never have, so that reaching for it is a build error. Behind that API sits the **endovisor**, a component inside the host kernel that creates, feeds, schedules and reclaims kernelets and gives them their devices. Where a hypervisor sits *beneath* its guests in hardware, the endovisor sits *inside* the host kernel and *beside* the kernelets, at the same privilege level, and the boundary is the language: the crate graph decides what a kernelet can name, and a table of C-ABI calls that carry names, never pointers, decides what may cross. Because vOSTD is OSTD's source, the virtualized API cannot drift from the API it virtualizes. The price is a second build of the kernel and a boundary that rests on the compiler and on OSTD's soundness rather than on hardware; per-kernelet page tables keep the host's stray pointers out of a kernelet, and the language keeps the kernelet's out of the host.

## How to read this book {#how-to-read}

You need to know Rust and roughly how an operating-system kernel is put together. Nothing else is assumed. The book is three volumes, and they are meant to be read in the order that suits the reader rather than the order they were written in.

- [**The Paper**](paper/abstract.md) is the idea in its most concise form, written as a research paper.
- [**The Blueprint**](blueprint/index.md) is the design document: every mechanism down to the types and the checks, the OSTD changes, the staged plan, the numbers that exist, and what must be verified. It is written so that a coding agent can implement from it. Its Overview and its Design chapter are written; the implementation plan, the evaluation plan and the limitations are still to come.
- [**The Notes**](notes/index.md) hold the working material behind the other two: today the inventory of the OSTD API the Design classifies and the register of every decision and assumption it makes; later the earlier design studies and the booted prototype, the cost accounting, and the survey of related technologies.

Logically the Notes came first, the Blueprint was built from them, and the Paper was distilled from the Blueprint.

If you read only one volume, read the Paper. If you will build it, read the Blueprint.
