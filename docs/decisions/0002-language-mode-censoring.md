# ADR 0002 — The census forces `-swift-version 5`

**Status:** accepted
**Date:** 2026-09-06
**Milestone:** M0
**Amends:** ROADMAP A2, SPEC §4.2
**Environment:** Swift 6.4 (swiftlang-6.4.0.33.1), Xcode 27.0 beta 6, macOS 27, arm64

## Context

ROADMAP A2 established that `-swift-version 6` censors the census: diagnostics become
errors, the compiler stops, and downstream diagnostics are never emitted. A2 concluded
that `strict-complete` is the only safe frequency source.

SPEC §4.2 defines `strict-complete` as `-strict-concurrency=complete` **under the
package's declared language mode**, matching SPI's invocation.

Those two statements are in conflict, and A2 did not notice. A package declaring
`swift-tools-version: 6.x` *is* in Swift 6 language mode. For such a package,
"strict-complete" and "swift6" are the same measurement, and A2's censoring applies to
the mode A2 nominated as uncensored.

## Evidence

Identical source, three configurations:

| Configuration | Diagnostics emitted |
|---|---|
| `tools-version: 5.10`, `-strict-concurrency=complete` | **4** (1 error, 3 warnings) |
| `tools-version: 6.0`, `-strict-concurrency=complete` | **1** (1 error) |
| `tools-version: 6.0`, `-strict-concurrency=complete`, forced `-swift-version 5` | **4** (1 error, 3 warnings) |

The source did not change. Only the declared language mode did. The override
(`-Xswiftc -swift-version -Xswiftc 5`) is accepted by SwiftPM and fully restores the
uncensored count.

## The problem this creates

Censoring is **correlated with package modernity**. A package that has adopted
`swift-tools-version: 6.x` reports fewer diagnostics than the same code would under
Swift 5 mode — not because it is cleaner, but because the compiler stops earlier.

A frequency distribution built this way understates diagnostics in modern packages and
overstates them in legacy ones. That is worse than a uniform bias: it is a bias aligned
with the exact variable a migration census is trying to measure, and it grows as the
ecosystem migrates.

## Decision

**The primary census mode is `strict-complete-v5`:** `-strict-concurrency=complete`
with `-swift-version 5` forced for every package, regardless of what it declares. This
is the only mode whose occurrence counts are comparable across packages.

**A second mode, `strict-complete-declared`, is retained** — `-strict-concurrency=complete`
under the package's declared mode, exactly matching SPI's invocation. It is not a
frequency source. It exists for comparability and for the finding below.

`swift6` as a separate mode is **deleted**, not deferred. It is now exactly
`strict-complete-declared` for modern packages and adds nothing.

## The finding this produces

The delta between `strict-complete-v5` and `strict-complete-declared`, per package, is
a **direct measurement of how much declared-mode measurement undercounts** — including
Swift Package Index's own published figures, which use the declared-mode invocation.

Nobody has quantified this. It costs one extra matrix column and it is a stronger,
more specific claim than "SPI discards the breakdown": it is a measurable bias in the
ecosystem's canonical instrument, with a number attached. Report it in M3.

**Caveat to state honestly in the write-up:** this does not mean SPI's totals are
simply too low. Migration to `tools-version: 6.x` pushes declared-mode counts down
while the underlying code may be improving at the same time. The two effects are
confounded in their published series and cannot be separated from outside. The census
can measure the *mechanism* on its own corpus; it cannot re-derive SPI's history.

## Risks

**Forcing `-swift-version 5` on Swift-6-era code may fail to compile.** Swift 6 mode is
mostly a tightening rather than a syntax change, so most code should typecheck, but
this is unverified at corpus scale. M1 must record per-package whether the forced-v5
build succeeded, and packages that fail under it are reported as such rather than
silently dropped — a silent drop would reintroduce exactly the modernity bias this ADR
removes.

**Divergence from SPI is now deliberate.** SPEC §4.2's instruction to match SPI's
invocation is superseded for the primary mode and preserved in
`strict-complete-declared`.

## Related M0 finding — errors halt the build in *both* modes

A2's framing implies `strict-complete` yields warnings and `swift6` yields errors. That
is too clean. Actor-isolation violations such as `actor_isolated_call_decl` are errors
even in Swift 5 language mode with strict concurrency, and any error still fails the
build.

The distinction that matters is therefore **not** warning-versus-error but **how far
the build gets before stopping**. Within a single frontend job all diagnostics are
emitted regardless of severity; across targets, an error in one target prevents
dependent targets from compiling at all, and their diagnostics are lost.

No `--continue-building-after-errors` option exists on `swift build`. **Open for M1:**
whether per-target invocation (building each target separately and tolerating failures)
recovers the lost downstream diagnostics, and at what cost. Until resolved, every run
record must store the set of targets that failed to build, so the denominator of any
coverage claim is honest.

## Related M0 finding — module caches must be shared per toolchain

Running a standalone swift.org toolchain against a newer Xcode SDK requires compiling
SDK `.swiftinterface` modules, which took minutes per toolchain on first use and
appeared as a hang.

ROADMAP F4 requires a clean build tree per `(package, toolchain, mode)` cell. That must
**not** be read as clearing the module cache: SDK modules are derived from the toolchain
and SDK, never from package sources, so they cannot leak package state between cells.
Use a per-toolchain `-module-cache-path` shared across all cells for that toolchain.
Clearing it per cell would add minutes to every cell of the matrix for no correctness
benefit.
