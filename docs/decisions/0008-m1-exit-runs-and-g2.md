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

Not yet run.
