# ADR 0008 — The M1-exit runs and G2 scoring (pre-registered)

**Status:** **accepted by the owner (2026-10-11)** via spec `docs/superpowers/specs/2026-10-11-s-emit-matrix-and-g2.md`. Everything above "Results" is pre-registered: it is committed before the first cell of these runs is built and is not edited after results are seen. If it turns out to be wrong, a new ADR says so.
**Date:** 2026-10-11
**Milestone:** M1 (exit)
**Operationalises:** ADR 0007 D8 (G2, redefined); ROADMAP A7 (M1 exit)
**Relates to:** ADR 0002, 0006, 0007; ROADMAP G2, A7, F1–F7

## Context

ADR 0007 selected `S-emit` (30 entries) by a macOS screen and redefined G2: among the 30, the fraction that emit ≥1 primary diagnostic on the Linux 6.4 column, and on nightly; below 50% on Linux 6.4 fails. It did not fix how a cell is scored, what happens to packages that fail to build on Linux, or which runs G2 reads. Those choices change the number, so they are fixed here before any result exists. No existing run satisfies the M1 exit either: `2026-10-04*` and `2026-10-10-macos*` predate `S-emit`.

## Decision

Run the whole corpus (all 66 entries; 65 runnable) twice per platform at one tools commit, and score G2 on the first Linux pass.

| Item | Fixed value |
|---|---|
| G2 population | The 30 `stratum: S-emit` entries in `corpus/packages.yaml` at this ADR's commit |
| Denominator | Always 30. No entry is dropped for any outcome |
| "Emits" on a column | The entry's `strict-complete-v5` cell is `built` **and** has ≥1 record with `attribution: primary` and `severity ≠ note` (ADR 0007 D1's record filter) |
| Not emitting | `built` without such a record; `build_failed`; `timeout`; `unsupported_tools_version`; `resolve_failed` |
| Why `built` only | On Linux a `build_failed` cell typically carries "no such module" errors for Apple frameworks. They are primary, non-note, and not caused by strict checking. The any-outcome fraction is reported alongside, labelled non-gating |
| `infra_error` | Each `infra_error` cell gets one retry (its cell directory is deleted and the same `census run` re-issued). If any `S-emit` 6.4 cell is still `infra_error`, or missing, G2 is **not evaluated**, and the report says why |
| Gating column | Linux `6.4` = `swift:6.4` @ `sha256:4601bf61dab9485a3e93087770b72d268737e945a5b000e2286b6cc48bb048b6`, aarch64, first pass (`<D>`), never the re-run |
| Threshold | `emits / 30 < 0.5` fails G2 (≤ 14 of 30). 15 of 30 passes |
| Reported, not gating | Nightly (`swiftlang/swift:nightly-main-jammy` @ `sha256:191f78f3b9570ccdd382437b07ea0e8f98750206b96c71bad4f9515ec3aed4d2`), 6.1, 6.2, 6.3; the macOS column; each column overall and per tertile |
| Other images | `swift:6.1` @ `sha256:6e43114610e161e38ad41636ebcafd6940dc67dfab355eace3a0ca100b2263db`, `swift:6.2` @ `sha256:eccc7a97f9b9881d9659e2e788081fd7675f86d39793b51200bfb178398b3784`, `swift:6.3` @ `sha256:cd45c27b3abc42310c33cfaf3008b18156cbdc9187834c9617e8f43a26d2675c`: the images `2026-10-04` recorded. No `docker pull` until the last run is committed |
| Guest | `census-macos`, restore digest `sha256:2f016638293c3e641b8b25391a76fbc16563b3711915a5551cf8aa0f5598a5c1`, Xcode 27.0; a fresh clone per run |
| Runs | `<D>` and `<D>-rerun` (Linux; `--jobs 1 --cpus 8 --memory-gb 7 --timeout-minutes 60`, the flags of the last set-identical pair); `<D>-macos` and `<D>-macos-rerun` (`--timeout-minutes 60`). `<D>` is the date the freeze is made |
| One tools commit | tools/ and corpus/ are byte-identical to the freeze commit for all four runs (`git diff <freeze> <run commit> -- tools corpus` is empty) and no `run.json` records `tools_git_dirty: true` |
| M1 exit | `census compare` SET-IDENTICAL for `<D>` vs `<D>-rerun` **and** for `<D>-macos` vs `<D>-macos-rerun` |
| Screen reproduction | `census screen reproduce screen-2026-10-10 runs/<D>-macos` SET-IDENTICAL: the macOS `S-emit` `strict-complete-v5` cells equal their screen pass-1 cells |
| A failed check | Investigated. A pair is not re-run until it comes out green. If an instrument bug is found and fixed, **both** passes of the affected pair are re-run at the fixed commit under new run ids |
| If G2 fails | The selector is investigated before M2 (ADR 0007 D8). `S-emit` is not re-selected, the screen is not re-run, and the threshold does not move, without a new ADR |

## What G2 does and does not test

G2 tests whether `S-emit` membership, measured on Xcode 27 on macOS, carries over to a different platform and toolchain. It does **not** test whether `S-emit` is representative of the ecosystem: it is selected on the outcome (ADR 0007, Known bias 1). Linux-only build failures of Apple-leaning packages lower the G2 fraction without saying anything about the selector. The non-emitting entries' outcomes are listed so that this is visible.

## Results

**G2 fails (8/30 on Linux 6.4), and M1 is not exited: neither pair is set-identical.** Each pair differs in exactly one cell, and both cells are `build_failed` on both passes. Screen reproduction holds (30/30). Nothing was re-run.

Pre-registration committed at `bb6073e`. Tools frozen at `553ba2f` (it includes four pre-freeze review fixes: gating image pinned, run manifest checked, I/O errors exit 2, image lookup retried). Runs `2026-10-11` (started 12:52Z) and `2026-10-11-rerun` (14:24Z) on Linux aarch64 (Docker 29.4.2); `2026-10-11-macos` (16:43Z) and `2026-10-11-macos-rerun` (19:05Z) on Xcode 27.0 (27A266a, Apple Swift 6.4), guest macOS 27.0.1 (26A434).

### Checks

| Check | Command | Result |
|---|---|---|
| One tools commit | `git diff 553ba2f <run commit> -- tools corpus` ×4 | all empty; `tools_git_dirty: false` ×4; one manifest hash (`bca2cc3e…`) ×4 |
| A7 Linux (M1 exit) | `census compare runs/2026-10-11 runs/2026-10-11-rerun` | **NOT SET-IDENTICAL**: 335 compared, 298 identical, 36 equal no-diagnostic outcomes, 1 differing (`6.4/strict-complete-v5/Quick/Nimble`, −0 +16) |
| A7 macOS (M1 exit) | `census compare runs/2026-10-11-macos runs/2026-10-11-macos-rerun` | **NOT SET-IDENTICAL**: 69 compared, 68 identical, 1 differing (`xcode-27.0/strict-complete-v5/customerio/customerio-ios`, −59 +0) |
| Screen reproduction | `census screen reproduce screen-2026-10-10 runs/2026-10-11-macos` | **SET-IDENTICAL**: 30 compared, 30 identical; no input mismatch |
| G2 | `census gate g2 runs/2026-10-11` | **G2 FAIL** (exit 1), `runs/2026-10-11/g2.json` |

### Outcomes per run

| run | cells | built | build_failed | unsupported_tools_version | resolve_failed | infra_error |
|---|---|---|---|---|---|---|
| `2026-10-11` | 335 | 124 | 175 | 29 | 7 | 0 |
| `2026-10-11-rerun` | 335 | 124 | 175 | 29 | 7 | 0 |
| `2026-10-11-macos` | 69 | 60 | 9 | 0 | 0 | 0 |
| `2026-10-11-macos-rerun` | 69 | 60 | 9 | 0 | 0 | 0 |

No `infra_error`, so no retry. Outcomes are equal cell by cell in both pairs (no `OUTCOME DIFFERS`).

### The two A7 differences

Both are `build_failed` on both passes, and in both one pass's diagnostics are a strict superset of the other's:

- `Quick/Nimble` on Linux 6.4: 53 `.dia` files on the first pass, 68 on the re-run; 3 primary errors on each; the re-run adds 8 warnings and 8 notes. The first error is in a different file on each pass.
- `customerio/customerio-ios` on macOS: 122 `.dia` files on the first pass, 74 on the re-run; the first pass adds 3 errors, 16 warnings, 40 notes (`dependency_scan_module_not_found` among them).

Probable mechanism (**not verified**): after the first failing compile job the build system stops scheduling, so how much of a failing package is compiled, and therefore which diagnostics exist, depends on parallel scheduling. Neither difference is in a `built` cell, and A7's `2026-10-04` pair (also with `build_failed` cells) was set-identical. Per this ADR the pairs are not re-run and the check is not relaxed. Whether A7 should be restated for `build_failed` cells is the owner's decision, in a new ADR.

### G2

| column | emits / 30 | % | any outcome (non-gating) | head | middle | tail |
|---|---|---|---|---|---|---|
| **6.4 (gating)** | **8** | **26.7%** | 24 | 2/10 | 2/10 | 4/10 |
| nightly | 8 | 26.7% | 24 | 2/10 | 2/10 | 4/10 |
| 6.3 | 9 | 30.0% | 26 | 2/10 | 2/10 | 5/10 |
| 6.2 | 8 | 26.7% | 25 | 1/10 | 2/10 | 5/10 |
| 6.1 | 8 | 26.7% | 24 | 1/10 | 2/10 | 5/10 |
| macOS (Xcode 27.0, `2026-10-11-macos`; not gating, never summed with Linux) | 30 | 100% | 30 | — | — | — |

Not emitting on Linux 6.4: 22 entries. 21 are `build_failed`; 1 (`dagronf/DSFAppearanceManager`) is `built` with no primary non-note diagnostic. Of the 9 `S-emit` entries that build on Linux 6.4, 8 emit. The `Quick/Nimble` A7 difference does not change G2: that cell is `build_failed` on both passes, so it does not emit on either.

First cause in the build log of the 21 `build_failed` (first pass): 11 a missing Apple module (`SwiftUI` ×3, `CoreLocation` ×2, `CoreGraphics` ×2, `OSLog`, `AVFoundation`, `Security`, `Combine`); 1 a missing `Foundation/Foundation.h`; 1 a missing `wayland-util.h`; 1 a build-tool plugin failure; 7 compile errors not classified further.

This is the case "What G2 does and does not test" anticipated: most of the failure is Linux portability of Apple-leaning packages, which the gating column cannot separate from the selector. Per ADR 0007 D8 and this ADR, the selector is investigated before M2; `S-emit` is not re-selected and the threshold does not move without a new ADR.

### Recorded deviations

- `2026-10-11-rerun` has no `image_id` on its 268 `swift:6.1`–`6.4` cells (nightly's 67 have it). `docker image inspect` of the bare `swift:` tags failed through all three retries at run start; the namespaced nightly tag resolved. Evidence the pinned images ran: the tags resolved to the pinned IDs in the preflight before the run and in `docker images --no-trunc` after it (all created 9 days earlier); no `swift` image was left dangling by a pull; each column's `toolchain_version` is identical to the first pass. Not fixed: a `tools/` change after the freeze would require re-running both Linux passes. G2 is scored on the first pass, where every cell has its pinned `image_id`, which `gate g2` asserts.
- The 7 `resolve_failed` Linux cells are package outcomes, equal on both passes.

### Not verified

- The scheduling mechanism behind the two A7 differences.
- The 7 unclassified Linux compile errors among `S-emit` (whether they are Apple-only API, a strict-concurrency error, or other).
- Why bare-tag `docker image inspect` fails intermittently on this Docker while `docker run` of the same tag succeeds.
