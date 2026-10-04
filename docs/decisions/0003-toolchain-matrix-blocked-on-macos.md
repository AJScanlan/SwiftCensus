# ADR 0003 — The toolchain matrix cannot run on macOS with one Xcode

**Status:** option A adopted for M1 by ADR 0004 (Docker is now installed); the macOS-column question moves to ADR 0004 §1. Open items below still stand.
**Date:** 2026-09-06
**Milestone:** M0 (gate G0)
**Affects:** ROADMAP A6, A12; SPEC §4.2

## G0 result: A1 holds, over a narrower range than intended

Identical probe source, `-swift-version 5 -strict-concurrency=complete`, same SDK:

| Toolchain | Result | Unique identifiers |
|---|---|---|
| 6.1.3 | **fails** — cannot parse the SDK's `Foundation.swiftinterface` | — |
| 6.2.4 | stalls (killed at ~5 min, ~1% CPU); inconclusive, same pattern | — |
| 6.3.3 | OK | 9 |
| 6.4 (Xcode 27b6) | OK | 9 |
| nightly 2026-08-30 | OK | 9 |

The identifier sets for 6.3.3, 6.4 and nightly are **byte-identical**, as are the
diagnostic group tags. **G0 passes** for the range that runs: `-debug-diagnostic-names`
is stable across three toolchains spanning two releases plus a development snapshot.
A1 stands.

It has *not* been tested across the full A6 range, because most of that range does not
run here.

## The blocker

Swift 6.1.3 against the macOS 27 SDK:

```
.../MacOSX.sdk/System/Library/Frameworks/Foundation.framework/Modules/
  Foundation.swiftmodule/arm64e-apple-macos.swiftinterface:22:62: error: expected '{' in struct
@dynamicMemberLookup public struct AttributeContainer : Swift::Sendable {
```

The emitted diagnostic id is `module_interface_build_failed_mismatching_compiler`. The
SDK's `.swiftinterface` files use qualified-name syntax the older parser rejects.

**Root cause, and it is structural.** On macOS, swift.org standalone toolchains do not
ship an SDK — they use Xcode's. Toolchain and SDK are therefore *coupled*: one installed
Xcode means one SDK, which means only toolchains near that SDK's vintage will run. A
five-column toolchain matrix on macOS needs five Xcodes.

On Linux the coupling does not exist: toolchains bundle their own stdlib and Foundation
and are self-contained. This is the same structural fact that makes Linux cheap and
elastic and macOS neither.

**Current machine state:** one Xcode (27.0 beta 6), SDKs `MacOSX27.sdk` only; no
container runtime installed (`docker`, `podman`, `colima`, `nerdctl`, `lima` all absent).
So neither the macOS multi-toolchain matrix nor the Linux matrix can run today.

## Options

**A — Install a container runtime; run the toolchain matrix on Linux.**
Toolchains are self-contained, so the matrix is clean and the SDK stops being a
confounder. Satisfies ROADMAP F3 containerisation as a side effect, and matches SPEC
§4.2's own cost note (Linux runners 1×, macOS 10×). Cost: one runtime install; the
Apple-SDK-only package subset stays macOS-only at a single toolchain.

**B — Install multiple Xcodes.**
Gives a macOS matrix, but the SDK then varies *with* the toolchain, so a diagnostic
change cannot be attributed to the compiler rather than the SDK — which defeats the
purpose of the matrix. Roughly 15–20 GB per Xcode, and older Xcodes are unlikely to run
on macOS 27 at all. **Not recommended.**

**C — Narrow A6 to what runs: 6.3 / 6.4 / nightly.**
Three columns, no new infrastructure, works today. Loses the 6.1 and 6.2 history — though
SPI already publishes 6.0–6.3 aggregates, so some historical context exists elsewhere.
Adequate for forward-looking drift detection, weaker for characterising the past.

## Recommendation

**A, with C as the interim.** Take C now so M0 can close and M1 can begin on three
columns; move the cross-toolchain dimension to Linux once a runtime is installed.

This amends A12 rather than reversing it. A12 made macOS canonical for the *headline
distribution*, which stands — the Apple-SDK packages and `@MainActor`-through-UI patterns
still only exist there. What moves to Linux is the *cross-toolchain* dimension, because
that is the axis macOS cannot hold constant. Restated:

- **Linux** — multi-toolchain matrix; drift detection; the nightly early-warning column.
- **macOS** — single current toolchain; breadth across Apple-SDK-dependent packages;
  the headline distribution.

## Consequence for A12's GA rule

A12 requires the canonical column to be GA, never beta. Today the newest GA toolchain is
**6.3**, since 6.4 ships only in Xcode 27 beta. Under option C the canonical column is
therefore 6.3, and 6.4 is a forward-looking column alongside nightly until Xcode 27 ships.

## Open

- Is 6.2.4 a hard failure like 6.1.3, or merely a very slow interface rebuild? It was
  killed at ~5 minutes at ~1% CPU. Retry with a long window before concluding.
- Does the Linux matrix reproduce the identifier stability G0 found on macOS? Must be
  re-run there once a runtime exists; G0's result does not transfer across platforms
  automatically.
