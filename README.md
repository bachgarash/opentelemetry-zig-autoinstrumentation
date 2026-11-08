# opentelemetry-zig-autoinstrumentation

eBPF-based OpenTelemetry autoinstrumentation for Zig binaries — traces from an
unmodified executable, with no SDK calls, no imports, and no recompilation.

Same spirit as [opentelemetry-go-instrumentation][obi] / OBI, aimed at Zig
instead of Go.

[obi]: https://github.com/open-telemetry/opentelemetry-go-instrumentation

> **Status: early research.** Nothing here instruments anything yet. What exists
> today is a target binary and a set of verified findings about what Zig's
> compiler output makes possible. See [Features](#features) for the plan and
> [Current state](#current-state) for exactly how far it goes.

## Why this is harder than Go

Go instrumentation has a stable foundation to stand on: a documented ABI, a
runtime with known structures, and `go:linkname`-visible internals. Zig gives
you none of that.

- **No stable calling convention.** Functions not marked `export` or
  `callconv(.c)` use an internal convention the compiler may change between
  releases. Arguments do not reliably land in the SysV registers.
- **No runtime to anchor to.** No scheduler, no goroutine IDs, no `g` pointer to
  hang trace context off.
- **Aggressive inlining.** Non-`pub` functions routinely vanish from the symbol
  table in release builds. DWARF still records where their code landed, so they
  stay reachable — but only by address, never by name.
- **DWARF is the only map.** Which means release builds without debug info are a
  genuinely open problem, not an implementation detail.

Establishing how much of this is tractable is the point of the early milestones.

## Layout

```
examples/http-minimal.zig   Instrumentation target: minimal std.http server
Makefile                    Build in every optimisation mode, inspect symbols/DWARF
```

## Quick start

Requires Zig 0.16, a kernel with BTF (`/sys/kernel/btf/vmlinux`), and binutils.

```sh
make run                # build Debug, serve on 127.0.0.1:8080
curl -i localhost:8080/hello

make syms               # build all 4 modes, show which keep the handler symbol
make modes              # compare binary sizes
make dwarf              # DWARF entry for handleRequest
make help               # list targets
```

Override the defaults as needed: `make syms FUNC=serveConnection`,
`make run PORT=9000`.

## Current state

Milestone 1 (binary archaeology) is done. The findings below are measured on
Zig 0.16.0, x86-64, kernel 7.2.15, not assumed.

### Symbols survive only in Debug

`handleRequest` is a normal non-`pub` function. Built four ways:

| Mode         | Symbol present | Size     |
|--------------|----------------|----------|
| Debug        | yes (`t`)      | 12.3 MB  |
| ReleaseSafe  | no             | 4.0 MB   |
| ReleaseFast  | no             | 4.0 MB   |
| ReleaseSmall | binary stripped| 167 KB   |

The symbol is local (`t`, `DW_AT_external: 0`), not global. Uprobes don't care
about binding, but anything resolving symbols by dynamic-symbol lookup will.

### A missing symbol is not a dead end

`handleRequest` disappears from `nm` in ReleaseFast because it was **inlined**,
not because the information was discarded. Zig does not strip in
ReleaseSafe/ReleaseFast — that build still carries 8 debug sections, and DWARF
records the inlined code's location:

```
DW_TAG_subprogram                     ← abstract root, no address
  DW_AT_name   : handleRequest
  DW_AT_inline : 1 (inlined)

DW_TAG_inlined_subroutine             ← concrete instance
  DW_AT_abstract_origin: <0xca89>
  DW_AT_ranges         : 0x1490
  DW_AT_call_line      : 51           ← the call site in serveConnection
```

Range list `0x1490` resolves to four discontiguous spans, the first at
`0x101ec7a`. A uprobe placed there fires when the inlined body is entered.

The cost is threefold: no symbol, so attachment is by computed offset only; no
stack frame of its own, so parameters must be read from `.debug_loc` location
lists that vary by PC range; and fragmented ranges, so "function entry" becomes
a judgement call. More loader work, not a different problem.

**ReleaseSmall and `-fstrip` are the real dead end** — zero debug sections, no
symbol table, nothing to attach to. Those need a socket-level fallback
(tracepoints on the syscalls the process makes, parsing HTTP off the wire),
which trades handler-level attribution for surviving any amount of stripping.

### DWARF gives full argument detail

In Debug, `handleRequest`'s `DW_TAG_formal_parameter` yields the name
(`request`), the type (`*http.Server.Request`), and a walkable reference to the
struct definition and its member offsets. That is sufficient to read request
fields out of target memory.

### The first argument arrives in RAX, not RDI

The critical finding. DWARF reports the parameter at `DW_OP_breg7 (rsp): 64`,
but that location only becomes valid once the prologue has run:

```asm
11d87b0:  push   %rbp
11d87b1:  mov    %rsp,%rbp
11d87b4:  sub    $0x90,%rsp
11d87bb:  mov    %rax,0x40(%rsp)    ; 0x40 = 64 — argument spilled from RAX
```

Two consequences:

1. **A uprobe at `low_pc` cannot use the DWARF location.** It fires before `rsp`
   is adjusted, so `rsp+64` holds garbage. DWARF describes the function body;
   uprobes fire at the entry. Reconciling the two is milestone 3.
2. **The argument is in RAX**, not RDI as SysV would require. Zig's internal
   convention, subject to change between compiler versions — so any probe
   depending on it needs a version-compatibility story (milestone 7).

### Virtual address vs file offset

The binary is `EXEC`, not PIE, so load addresses are fixed — but uprobes still
want a file offset:

```
.text        vaddr 0x1024000   file offset 0x8ee000
handleRequest vaddr 0x11d87b0
file offset = 0x11d87b0 - 0x1024000 + 0x8ee000 = 0xaa27b0
```

`bpftrace`'s `uprobe:/path:symbol` form does this for you. Probing an unnamed
address, or an offset mid-function, means doing the arithmetic yourself. A PIE
build adds a runtime slide on top.

### Zig emits DWARF that GNU binutils can't parse

`readelf`/`objdump` report `Bogus end-of-siblings marker`, `User TAG value:
0xfdb1`, and unknown attributes around `0x2ccd`. Zig uses vendor extensions in
the `DW_TAG_lo_user` range and binutils loses its place. The data is fine; use
`llvm-dwarfdump` for anything structural.

## Features

### Tracing

- [ ] HTTP server spans — method, path, status, duration
- [ ] HTTP client spans from `std.http.Client`
- [ ] W3C `traceparent` injection on outbound requests
- [ ] `traceparent` extraction on inbound requests
- [ ] Correct parent/child nesting across two instrumented services

### Export

- [ ] OTLP/HTTP exporter
- [ ] OTLP/gRPC exporter
- [ ] Resource attributes (service name, version, host)
- [ ] Configurable sampling

### Attaching

- [ ] Attach to a running process by PID
- [ ] Attach by executable path before launch
- [ ] Survive target restarts
- [ ] Auto-discover Zig processes
- [ ] Multiple targets at once

### Target support

Three tiers, by how much the compiler left behind:

- [x] **Debug** — symbol + `DW_AT_location`; attach by name
- [ ] **ReleaseSafe / ReleaseFast** — no symbol, but DWARF inlined ranges and
      location lists; attach by computed offset
- [ ] **ReleaseSmall / `-fstrip`** — nothing; needs the socket-level fallback

Plus, orthogonal to the tiers:

- [ ] PIE binaries (load-address slide)
- [ ] Multi-threaded servers and concurrent connections
- [ ] More than one Zig version (internal ABI is unstable)

### Tooling

- [x] Minimal `std.http` target server
- [x] Build in all four optimisation modes side by side
- [x] Symbol and DWARF inspection targets
- [ ] eBPF program and userspace loader
- [ ] DWARF reader: inlined ranges and `.debug_loc` location lists
- [ ] Socket-level fallback for stripped binaries
- [ ] Integration test asserting spans reach a collector

Not planned for now: non-x86-64 architectures, anything async.

## License

[Apache 2.0](LICENSE)
