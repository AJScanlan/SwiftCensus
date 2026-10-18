# ADR 0009 — G2 failed: the investigation, and the Linux column's scope

**Status:** **proposed (2026-10-18)**, for owner acceptance. Written **after** the G2 result was seen; nothing here is pre-registered, and nothing here changes that result.
**Date:** 2026-10-18
**Milestone:** M1 (exit)
**Responds to:** ADR 0008 Results (G2 FAIL); ADR 0007 D8 ("below 50% on Linux 6.4 fails G2, and the selector is investigated before M2")
**Relates to:** ADR 0003, 0006, 0007, 0008; ROADMAP G2, A12, F6

## The result, which stands

**G2 failed.** 8 of the 30 `S-emit` entries emit on the Linux 6.4 column (26.7%), below the pre-registered 50%. This ADR does not re-score G2, does not move its threshold, does not change its population, and does not call it passed. Every later document that mentions G2 reports it as failed, with a pointer here.

## Why this ADR exists

D8 attaches one obligation to a G2 failure: investigate the selector before M2. ADR 0008 forbids re-selecting `S-emit`, re-running the screen, or moving the threshold without a new ADR. This is that investigation, and the decision that follows from it. It answers one question: **is there evidence the selector is broken?**

## What G2 was meant to detect

ADR 0007 ("Why G2 is not tautological") says G2 fails "a selector that picked macOS-SDK noise, or diagnostics that exist only on Xcode 27's compiler". The investigation tests both, using only committed data (`runs/2026-10-11`, `runs/2026-10-11-macos`). Nothing was re-run.

## Findings

### 1. The gating column cannot observe most of the population

| stratum | builds on Linux 6.4 | builds on macOS (Xcode 27.0) |
|---|---|---|
| `S-emit` | 9/30 (30%) | 30/30 (100%) |
| `S-control` (uniform draw from the SPI list) | 12/29 (41%) | 20/29 (69%) |
| `S-anchor` | 4/4 | 4/4 |

21 of the 22 non-emitting `S-emit` entries are `build_failed` on Linux. 12 of the 21 fail on a missing Apple framework or header (ADR 0008 Results). `S-control` shows this is a property of the ecosystem, not of `S-emit`: a uniformly drawn package builds on Linux less than half the time. Of the 9 `S-emit` entries that do build on Linux, one, `dagronf/DSFAppearanceManager`, wraps every source file in `#if os(macOS)`, so on Linux it compiles an empty module. **The Linux column could measure 8 of the 30. All 8 emit.**

### 2. The 8 emit on every Linux toolchain, not only 6.4

| entry | 6.1 | 6.2 | 6.3 | 6.4 | nightly | primary non-note, macOS / Linux 6.4 |
|---|---|---|---|---|---|---|
| `AudioKit/Tonic` | E | E | E | E | E | 3 / 3 |
| `DeclarativeHub/ReactiveKit` | E | E | E | E | E | 60 / 55 |
| `dev-hamin-kim/HangulKit` | E | E | E | E | E | 2 / 2 |
| `luizmb/FP` | tools-version | tools-version | E | E | E | 133 / 121 |
| `s2mr/L10nLint` | E | E | E | E | E | 15 / 23 |
| `segmentio/Sovran-Swift` | E | E | E | E | E | 5 / 5 |
| `swiftlang/example-package-figlet` | E | E | E | E | E | 1 / 1 |
| `weppos/uddf-swift` | E | E | E | E | E | 2 / 2 |

E = `built` with ≥1 primary non-note diagnostic. "tools-version" = `unsupported_tools_version`.

### 3. The macOS diagnostics are concurrency diagnostics, not SDK noise

Over the 30 entries' `strict-complete-v5` cells on macOS there are 911 primary non-note diagnostics. 853 (93.6%) are in a concurrency diagnostic group (`MutableGlobalVariable` 221, `SendingRisksDataRace` 156, `SendableClosureCaptures` 132, `ActorIsolatedCall` 71, `SendableMetatypes` 40, `RegionIsolation` 38, and smaller), or are ungrouped with a concurrency identifier (`converting_noattrfunc_to_type` 89, `actor_isolated_non_self_reference` 47, and smaller). 58 (6.4%) are not concurrency diagnostics: deprecation groups, value conversion, unused values, implicit strong capture, unreachable code, access control.

The split is by group and identifier name, as the author read them. Groups whose name is not plainly about concurrency were counted as non-concurrency, which leans toward the noise hypothesis. These counts include diagnostics already present under `minimal-v5`. `screen_count`, which selected the entries, counts only what strict checking adds, so the selection signal is if anything more concurrency-specific than this.

### 4. The screen reproduces

`census screen reproduce screen-2026-10-10 runs/2026-10-11-macos`: 30/30 set-identical (ADR 0008 Results). The measurement that selected `S-emit` gives the same answer a week later in a fresh guest.

## Conclusion

**No evidence the selector is broken.** Where the Linux column can see an `S-emit` package's code, the package emits, on all five toolchains. On macOS the diagnostics that put packages in `S-emit` are overwhelmingly concurrency diagnostics.

**The defect is in the gate.** ADR 0007 D8 placed G2 on a column that cannot observe 70% (21/30, 22/30 counting the empty module) of its population, and that failure rate was already visible before D8 was written: `runs/README.md` recorded roughly 40% of `S-control` cells as `build_failed` on Linux on 2026-10-05 (`9893191`), five days before ADR 0007 (`7a0e916`). A Linux build failure scores as "not emitting" (ADR 0008, correctly, since dropping it would have made G2 easier to pass). As a result, G2 mostly measured Linux portability. That was the authors' design error, not a property of the selector.

### What the investigation does not establish

- **Toolchain specificity is barely tested.** Linux 6.4 and Xcode 27's Swift 6.4 are the same compiler release, so the gating column was mainly a platform test. The cross-toolchain evidence (finding 2) covers 8 packages, and 5 of them have ≤5 diagnostics on Linux 6.4. ADR 0007 Known bias 3 ("one toolchain defines membership") stands, unchanged, and goes into the M3 write-up.
- **Nothing about representativeness.** `S-emit` is selected on the outcome (ADR 0007 Known bias 1). This investigation asked only whether the selector picks genuine concurrency emitters.
- **The 7 unclassified Linux compile errors** among `S-emit` (ADR 0008 Results) are still unclassified. They affect only how the Linux non-emitters split, not findings 1–4.
- n = 8 is small. "All 8 emit" is not evidence that the 22 unobserved entries would also emit on Linux. It is only an absence of evidence against the selector.

## Decision

1. **G2 is recorded as failed.** The result is not restated, re-scored or replaced, and no substitute gate is evaluated in its place.
2. **The D8 obligation is discharged by this investigation.** `S-emit` is kept as selected (ADR 0007, `06fce75`). Nothing is re-drawn, re-screened or re-sampled.
3. **G2's failure does not by itself block M2.** D8 required an investigation, not a pass, and this ADR is that investigation. **M2 is still blocked by the M1 exit:** neither A7 pair is set-identical (ADR 0008 Results), which is a separate decision.
4. **Linux is scoped as the reproduction and toolchain-trend path (A12), and is never a gate on a stratum selected on macOS.** Concretely:
   - Every Linux figure is reported with its observable denominator: the cells that built and compiled package code, out of the cells attempted. A Linux rate is never stated over a denominator that includes packages Linux could not build.
   - Linux and macOS figures stay separate, never summed or pooled (F6, unchanged).
   - Linux is not dropped. It is the only platform with the five-toolchain matrix, and the only way someone without a Mac can reproduce the census. Dropping it would undo A12.
5. **Future gates state their power before they are pre-registered.** A gate's pre-registration must give the share of its population the gating measurement can observe, estimated from runs already committed, and a minimum below which the gate reports **underpowered** instead of pass or fail. For D8, the committed `S-control` runs would have put the observable share near 60% at best (the Linux build rate of a uniform draw), before any adjustment for `S-emit` being selected on macOS. In fact it was 27%. This applies to gates written from now on. It is not applied to G2 retroactively.

## Consequences

- The M3 write-up reports: G2 failed (8/30), why (finding 1), what the investigation found (findings 2–4), and what it does not establish (above). The failure is part of the published record, not a footnote.
- `runs/README.md` and the ROADMAP keep saying "G2: FAIL". This ADR adds a pointer and changes no number.
- Rule 4 applies at M2: any per-toolchain trend reported from Linux runs uses only cells that built.
- The remaining M1 decision is A7 for `build_failed` cells. It is independent of this ADR.
