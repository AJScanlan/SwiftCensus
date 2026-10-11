# ADR 0007 — `S-emit` by a macOS screen (pre-registered)

**Status:** **accepted by the owner (2026-10-10)** (decisions D1–D12 of the screen spec). Everything above "Results" is pre-registered: it is fixed before the first screening build and is not edited after results are seen. If it turns out to be wrong, a new ADR says so and the screen is re-run.
**Date:** 2026-10-10
**Milestone:** M1 (corpus)
**Amends:** ROADMAP A3 (the `S-emit` sampling frame); ADR 0004 §4 (adopts its fallback, "option 4")
**Relates to:** ADR 0001, 0002, 0006; ROADMAP G2, A7, A8, F1–F4; spec `docs/superpowers/specs/2026-10-10-macos-screen.md`

## Context

`S-emit` exists so that the census contains enough emitting packages that the distribution is not near-empty (A3). The plan was to sample it from SPI's per-package data-race counts. Those counts cannot be fetched: swiftpackageindex.com is behind a bot challenge, `robots.txt` disallows `/api/`, the owner chose not to defeat either, and no export has been supplied. This ADR replaces SPI's count with our own measurement on the canonical platform (ADR 0006).

## Decision

Screen a seeded uniform draw on macOS. Count what strict concurrency checking adds over Swift 5 mode's defaults. Define `S-emit` as a tertile sample of the candidates whose count is above zero.

**Consequence: membership is defined by the same build the census later measures.** On the screened toolchain and platform, an `S-emit` package's `strict-complete-v5` primary count is at least its `screen_count` (it also includes diagnostics already present under `minimal`), and is non-zero by construction. `S-emit` frequencies are therefore conditioned on "emits > 0". They are never an ecosystem estimate and are always reported separately from `S-control`.

### Pre-registration

| Item | Fixed value |
|---|---|
| Frame (D2) | `SwiftPackageIndex/PackageList` @ `4dc1035a98457e87f4d2c5649a33cd43ee6b80e8`, the commit `S-control` was drawn from |
| Order (D3) | Seed `20261004`. The same SplitMix64 Fisher–Yates over the sorted `owner/repo` ids as `S-control`. Every id in `corpus/packages.yaml` (all strata, skipped entries included) is a consumed position and is skipped |
| Count (D4) | **300** eligible candidates, fixed in advance. No stopping early. Candidates that fail to resolve are recorded `unresolvable` and are not replaced |
| Extension (D5) | If fewer than **45** stable emitters remain after the 300: **one** extension of +150, continuing the same order after the last drawn position. Then proceed with whatever exists |
| Eligibility | GitHub repository; not archived or disabled; pushed within 365 days of the draw date; default-branch HEAD pinned to a 40-character SHA at draw time |
| Platform and toolchain (D7) | `macos-spm`, Xcode 27.0's Swift, in a fresh clone of the `census-macos` guest per batch of 50 |
| Modes | `strict-complete-v5` (`-strict-concurrency=complete`, `-swift-version 5` forced) and `minimal-v5` (identical but `-strict-concurrency=minimal`) |
| Screen count (D1) | `primaryKeys(cell)` = multiset of `(id ?? "text:"+text, path, line, col)` over records with attribution `primary` and severity ≠ `note`. `screen_count = size(primaryKeys(complete) − primaryKeys(minimal))` (multiset difference, left minus right) |
| Severity | **Not** in the count key, unlike the A7 key: a diagnostic that is a warning under one mode and an error under the other was not added by strict checking |
| `built` requirement | The complete cell must be `built`. If it has ≥1 primary non-note diagnostic, the minimal cell must also be `built`. A complete cell with 0 such diagnostics has count 0 and no minimal build (early exit) |
| Status | `emitter` (count > 0); `clean` (0 diagnostics, or count 0); `not_screenable` (complete is `build_failed`, `unsupported_tools_version`, `resolve_failed` or `timeout`); `minimal_failed`; `unresolvable` (`census resolve` failed); `infra_error` (after one retry); `unstable` (below) |
| Stability (D9) | Emitters only are re-run, both modes, in fresh clones, into `runs/<id>-macos-verify`. An emitter whose verify-pass `screen_count` differs, or whose complete or minimal outcome differs, is `unstable`: excluded from sampling, kept in the results and the denominator. Nothing is averaged and neither pass is preferred |
| Sampling (D11) | **30** from the stable emitters, tertiles (head / middle / tail) by `screen_count` descending, seed `20261010`, via `Selection.sampleAcrossDistribution`. Fewer than 30, or an empty tertile: take what exists and say so; never pad |
| `S-emit` entries | At the **screened** SHA (never re-resolved), `platforms: [linux-spm, macos-spm]`, with `screen_id` and `screen_count_at_selection`. The screened `.resolved` bytes are copied into `corpus/resolved/` unchanged |
| Not screenable (D6) | iOS-only and other packages that do not build under `swift build` on macOS are recorded and excluded from `S-emit`, but stay in the denominator |
| Raw output (D10) | Every screen cell's raw bytes are committed (estimated ~45 MB) |
| Candidates stratum (D12) | `Stratum.screen` (`"screen"`). Candidates are never written into `corpus/packages.yaml` as `S-emit` |
| G2, redefined (D8) | Among the 30 `S-emit` packages: the fraction that emit ≥1 primary diagnostic **on the Linux 6.4 column**, and the fraction on nightly. **Below 50% on Linux 6.4 fails G2**, and the selector is investigated before M2 |

### Why G2 is not tautological

ROADMAP G2's original question ("did `S-emit` actually emit?") cannot fail on the screening column, because membership *is* "emitted on that column". The redefined G2 asks it on a different platform (Linux) and a different toolchain (nightly). A selector that picked macOS-SDK noise, or diagnostics that exist only on Xcode 27's compiler, fails it.

### Implementation choices the spec did not fix (reviewed by the owner in the plan)

- Batches run through `census screen batch`, which plans its own cells: complete first, then minimal only where needed, in one guest clone. `census run` gains no `--mode` flag.
- A complete cell that ends in `timeout` is `not_screenable` (reason `timeout`).
- The screen's `provenance.json` and `failures.json` live in `screens/<id>/resolved/`.
- `results.json` records `verify_screen_count` for every emitter. `complete_outcome` is absent for `unresolvable` candidates.
- `census screen collect --with-verify` fails if the stable emitters' cells are not A7 set-identical across passes.
- `candidates.yaml` is in draw order; batches are positional slices of 50.

## Relationship to SPI data

If SPI's export arrives later, `S-emit` is **not** re-drawn. The export becomes a validation join: SPI's declared-mode count against the screen's count, per package. That measures how far SPI's figure departs from `strict-complete-v5` (ADR 0001's open question; ADR 0002's censoring claim). The two selection signals are never mixed in one stratum.

## Known biases

1. **Selected on the outcome.** `S-emit` is truncated at zero by construction. Never pool it with `S-control` without stated weights.
2. **iOS-only packages are `not_screenable`.** SPI includes them (its iOS builds use `xcodebuild`); we do not (A11 scope). The size of this exclusion is reported as a number in the denominator table.
3. **One toolchain defines membership.** Packages that emit only on other toolchains are missed.
4. **A failed build censors.** A `build_failed` or `timeout` candidate may emit; we cannot see it. It is excluded, not counted as zero.
5. **`-strict-concurrency=minimal` is the baseline.** The count is what strict checking *adds to Swift 5 mode's defaults*, which is what a migrating developer experiences.
6. **"Active" is approximated** by a GitHub push within 365 days (ADR 0004 §5).
7. **Instability is checked for emitters only.** A non-emitter that would flip to emitter on a re-run is a risk stated here, not closed.

## Consequences

- The screen yields a second product: the **emit rate in a uniform sample**, with its denominator. Every candidate's outcome is committed, not just the emitters'.
- `Mode.allCases` now includes `minimal-v5`, so future `run.json` files list it (spec §6, G10). Committed runs are untouched.

## Results

Screen `screen-2026-10-10`, run 2026-10-11 (01:53–05:49Z) on Xcode 27.0 (27A266a, Apple Swift 6.4, swiftlang-6.4.0.34.1), guest macOS 27.0.1 (26A434). Candidates committed at `048b383`; outputs at `e412d5b`..`60d1c2e`; selection at `06fce75`.

**N drawn: 300. D5 was not applied** (47 stable emitters ≥ 45).

### Denominator (`census screen collect --with-verify`)

| status | count |
|---|---|
| drawn | 300 |
| unresolvable | 2 |
| not_screenable | 97 |
| &nbsp;&nbsp;build_failed | 97 |
| clean | 151 |
| emitter | 47 |
| unstable | 0 |
| minimal_failed | 3 |
| infra_error | 0 |
| sum | 300 |

`clean` splits as 119 with 0 primary non-note diagnostics under `strict-complete-v5` and 32 with ≥1 diagnostic but `screen_count` 0.

### Emit rate

- `emitter / drawn` = 47 / 300 = **15.7%**.
- `emitter / (drawn − unresolvable − not_screenable)` = 47 / 201 = **23.4%** (screenable candidates only; `minimal_failed` stays in this denominator).

### Stability

Verify pass `runs/screen-2026-10-10-macos-verify`: 47 emitters × 2 modes = 94 cells. Every emitter's `verify_screen_count` equals its `screen_count`, and no outcome differs. A7 over the 47 stable emitters: 94 cells compared, 94 set-identical. **Unstable: 0.**

### Distribution and selection

Stable-emitter `screen_count`, descending (sum 1312): 174, 151, 133, 105, 89, 70, 60, 55, 54, 54, 45, 42, 41, 34, 24, 17, 15, 15, 13, 12, 11, 11, 8, 8, 7, 7, 7, 6, 5, 5, 5, 3, 3, 3, 3, 2, 2, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1.

| tertile | emitters | `screen_count` range | selected |
|---|---|---|---|
| head | 16 | 174–17 | 10 |
| middle | 16 | 15–3 | 10 |
| tail | 15 | 3–1 | 10 |

The middle/tail cut falls inside the four-way tie at count 3; ties are ordered by URL, so two count-3 packages are `middle` and two are `tail`. `S-emit` = 30, seed `20261010`. Every selected entry's `corpus/resolved/*.resolved` is byte-identical to the screened one.

### Unresolvable

- `Blaizzy/mlx-audio`: no `Package.swift` at the drawn SHA.
- `mapbox/mapbox-navigation-ios`: a binary target's download returned HTTP 401.

### `minimal_failed`

All three are `built` under `strict-complete-v5` and `build_failed` under `minimal-v5`. The two cells' swiftc invocations differ only in `-strict-concurrency=`. The errors appear only under `minimal-v5`; the same source lines produce no diagnostic under `strict-complete-v5`.

- `ezefranca/BibTeXKit` (complete: 2 primary diagnostics): 2 × `actor_isolated_call_decl` (error), at default argument values (`clipboardWriter: … = BibTeXSystemClipboard().write`, `feedback: … = BibTeXCopyFeedback()`).
- `ibo2001/MushafImad` (complete: 4): 4 × `actor_isolated_non_self_reference` (error), at default argument values (`verse: Verse = .mock`).
- `twinkling-reality/opennook` (complete: 3): 1 × `actor_isolated_call_decl` (error) in top-level code in `Examples/ShowcaseNook/main.swift`, plus 1 × `actor_isolated_non_self_reference` (warning).

The status tool's expectation for this status was "~0". A probable mechanism for the first two is that `-strict-concurrency=complete` enables isolated default values (SE-0411) and `minimal` does not. That is **not verified**, and opennook's site is not a default argument. Consequence for D1: `minimal-v5` is not a strict subset of `strict-complete-v5`.

### Observed during the run

- `googleads/swift-package-manager-google-programmatic-access-library-tvos` is `not_screenable` (`build_failed`). Its only error is `NSCocoaErrorDomain Code=513` (a file "couldn't be removed because you don't have permission"), not a compiler diagnostic. It was classified by outcome, not retried as `infra_error`.
- Of the 97 `not_screenable`, the failures inspected were at dependency scan or link time (`UIKit`/`MobileCoreServices` not found, `.xcframework`s without a macOS slice). They were not individually classified.

### Not verified

- The stability of non-emitters (Known bias 7).
- The SE-0411 explanation above, and the cause of opennook's error.
- Whether the Code 513 package would have built on a retry.
- The per-reason breakdown of the 97 `build_failed` (iOS-only and other).
- G2 (Linux 6.4 and nightly): it needs the `S-emit` matrix runs, which have not been done.
