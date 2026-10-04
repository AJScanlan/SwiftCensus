# ADR 0005 — G0 re-checked on Linux: 6.1 hides identifiers behind a wrapper

**Status:** open — requires a decision (affects M2, not M1's exit)
**Date:** 2026-10-04
**Milestone:** M1 (gate G0, re-run as ADR 0003 required)
**Affects:** ROADMAP A1, A5, A6; SPEC §5.2

## Result

ADR 0003 verified G0 on macOS for 6.3, 6.4 and nightly only, and required a re-run on Linux once
a container runtime existed, covering the full A6 range. This is that re-run: one probe source
(`swiftc -typecheck -swift-version 5 -strict-concurrency=complete -debug-diagnostic-names
-print-diagnostic-groups`) in the official `swift:6.1`, `6.2`, `6.3`, `6.4` and
`swiftlang/swift:nightly-main-jammy` images, eight diagnostics each.

| Comparison | Identifier sets |
|---|---|
| 6.2 vs 6.3 vs 6.4 vs nightly | **identical** (rendered text also identical for 6.3 vs 6.4) |
| 6.1 vs every later toolchain | **differ on one construct** |

The differing construct is a stored property of a `Sendable` struct whose type is not `Sendable`:

| Toolchain | Text | Identifier |
|---|---|---|
| 6.1 | `…has non-sendable type…; this is an error in the Swift 6 language mode` | `error_in_future_swift_version` |
| 6.2 – nightly | `…has non-Sendable type…; this is an error in the Swift 6 language mode` | `non_concurrent_type_member` |

`error_in_future_swift_version` is not the construct's identifier. It is the generic wrapper the 6.1
compiler uses for any "warning now, error in Swift 6" diagnostic, so in 6.1 it stands in for many
unrelated constructs. Under the census's primary mode (`-swift-version 5`) those warn-until-6
diagnostics are a large share of what is emitted.

A second 6.1 difference: `[#ActorIsolatedCall]` is absent from `actor_isolated_call_decl` in 6.1
and present from 6.2. A6's reason for choosing 6.1 was that it has `-print-diagnostic-groups`; the
flag exists, but not every diagnostic carries its group yet, so A5's `ungrouped` class is
toolchain-dependent as well as diagnostic-dependent.

## What this means for G0

G0's own wording is "A1 dies here if identifiers differ across toolchains for the same construct",
with the consequence "A1 reverts, SPEC §5.2's `.def` matcher gets built, M2 roughly triples".
Strictly read, that trigger has fired for the 6.1 column. A narrower reading is also defensible:
A1 holds for 6.2 and later, and fails for 6.1 only on wrapped diagnostics. **That is the owner's
call and is not made here.** ROADMAP §0 also says not to re-litigate a gate after seeing data, so
the choice should be made once, in this ADR.

## Options

- **A — Narrow the matrix to 6.2 and later.** Delete the 6.1 column. A1 holds across everything that
  remains. Loses the oldest column; SPI publishes older aggregates elsewhere. Honours "prefer
  deleting scope".
- **B — Keep 6.1, treat the wrapper as unidentifiable.** Report `error_in_future_swift_version`
  as its own opaque bucket and exclude it from cross-toolchain comparison. Keeps the column but
  makes 6.1 incomparable for exactly the diagnostics that matter most under v5.
- **C — Build the `.def` matcher for 6.1 only.** The documented contingency, scoped to one toolchain.
  Most work; recovers real identifiers for the wrapped diagnostics.

## M1 consequence

None for M1. All five columns run and every cell stores the identifier as the compiler printed it
plus the rendered message (A1's fallback), so no option is foreclosed by data already collected.
M2 must not aggregate the 6.1 column across toolchains until this is decided.
