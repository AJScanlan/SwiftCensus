# Spec (handoff) — A7 restated, image-ID fix, fresh M1-exit runs

**Status:** the decisions are the owner's (ADR 0010, accepted 2026-10-18). This document was written by the previous session as a handoff. **The owner reviews it at the start of the next session**, before a plan is written or code changes.
**Branch:** `m1/s-emit-matrix` (pushed), worktree `/Users/aj/iOS/SwiftCensus/.claude/worktrees/s-emit-matrix`. Continue on it.
**Implements:** ADR 0010 rules 2–6. **Does not implement:** M2 (rule 1 is enforced when M2's frequency code is written), G2 (stays failed, ADR 0009).

## 0. Where things stand

- **ADRs to read first:** 0007 (S-emit screen), 0008 (M1-exit runs, G2; its Results), 0009 (G2 failed; investigation; Linux scope), 0010 (this decision, pre-registered).
- **Done:**
  - Runs `2026-10-11`, `2026-10-11-rerun` (Linux), `2026-10-11-macos`, `2026-10-11-macos-rerun` (macOS), committed.
  - G2: **FAIL** (8/30), recorded, investigated, closed (ADR 0009).
  - A7 as written: **FAIL** on both pairs, one `build_failed` cell each (ADR 0008 Results; mechanism in ADR 0010).
- **M1 is not exited.** The only path, per ADR 0010, is a fresh pair per platform under restated A7.
- **Branch state:** `m1/s-emit-matrix` sits on `m1/screen-results`, which sits on `m1/matrix-runner`. None of them is merged into `main`. The owner's main checkout (`/Users/aj/iOS/SwiftCensus`) is on `m1/matrix-runner`, which is behind. Do the work in the worktree.
- **The worktree's `work`** is a symlink to `/Users/aj/iOS/SwiftCensus/work` (source cache, SwiftPM mirror, 7 GB), excluded via `.git/info/exclude`. If the worktree is recreated, recreate the link.
- Previous spec and plan, whose Tasks 7–12 are reusable almost verbatim: `docs/superpowers/specs/2026-10-11-s-emit-matrix-and-g2.md`, `docs/superpowers/plans/2026-10-11-s-emit-matrix-and-g2.md`.

## 1. Code changes (only these: ADR 0010 rule 4)

### 1.1 A7 restated in `RunComparison` (`tools/Sources/CensusRunner/Compare.swift`)

- `Report` gains `failedBuildDiffering: [CellDifference]`. In `compare`, a cell whose outcome is `buildFailed` on both sides with a non-empty multiset difference goes there, not into `differing`.
- `isSetIdentical` is unchanged in form (`differing`, `outcomeMismatches`, `onlyInLeft`, `onlyInRight` all empty). It now ignores `failedBuildDiffering` by construction.
- `printComparison` (`tools/Sources/census/Census.swift`) prints each as `FAILED-BUILD DIFFERS (not gating, ADR 0010) <key>: -n +m`, plus a count in the summary line.
- **Callers to check:**
  - `census compare`;
  - `census screen collect --with-verify` (`tools/Sources/census/Screen.swift:224`, all 47 cells `built`, so expect no change: re-run it and confirm `94 cells compared, 94 set-identical` and an empty `git status screens/`);
  - `ScreenReproduction` (its 30 cells are `built`).
- **Tests (swift-testing, `tools/Tests/CensusRunnerTests/RunnerTests.swift` `RunComparisonTests`):**
  - a `build_failed` pair with differing diagnostics → set-identical, reported in `failedBuildDiffering`;
  - a `built` pair with differing diagnostics → not set-identical;
  - `built` vs `build_failed` → not set-identical (outcome mismatch);
  - identical `build_failed` → identical, not reported.
- **Real-data check:** `census compare runs/2026-10-11 runs/2026-10-11-rerun` should now print SET-IDENTICAL with one `FAILED-BUILD DIFFERS` (Nimble). **Do not record that as the M1 exit** (ADR 0010: those pairs are not re-evaluated as a substitute). It only proves the code matches the rule.
- Update the `CellOutcome.buildFailed` doc comment (`tools/Sources/CensusCore/CellRecord.swift:7`). It currently says "still data". Make it say the cell is captured and committed but not a frequency source (ADR 0010).

### 1.2 The `image_id` lookup (`MatrixRun.imageID`, `tools/Sources/CensusRunner/MatrixRun.swift`)

Evidence from 2026-10-11:
- `docker image inspect --format '{{.Id}}' swift:6.x` (bare tag) intermittently reports "No such image" for a present image, sometimes for more than the current retry window (3 tries, 1 s apart). In `2026-10-11-rerun` all four bare `swift:` tags failed at run start, so 268 cells have no `image_id`.
- The namespaced `swiftlang/swift:nightly-main-jammy`, the fully qualified `docker.io/library/swift:6.1`, and `docker images --no-trunc swift` never failed in the probes. The sample is small; this is not proof.
- Multi-argument `docker image inspect a b` reports the bare `swift:` tags missing.
- `docker run swift:6.x` itself worked throughout: the builds ran on the pinned images.

Suggested fix (the owner may choose otherwise):
- Resolve through the fully qualified reference (`docker.io/library/` prefix for single-component names), falling back to the `docker images --no-trunc` listing.
- **Make an unresolved image ID refuse the run before any cell is built**, instead of recording `nil`. P3: fail loud.

Test the pure parts (reference qualification, the fallback order through an injected resolver) with swift-testing. `scripts/matrix-preflight.sh` (not under `tools/`, so not frozen) should resolve the same way.

### 1.3 Before freezing: review

Have a fresh reviewer (most capable model) review the diff **before** the freeze. In the last session the pre-freeze review found 4 Important issues. A review fix after the freeze forces both pairs to be re-run.

## 2. Runs (ADR 0010 rule 3)

Same procedure as plan 2026-10-11 Tasks 8–11, with `<D2>` = the freeze date:
- Write `work/m1-exit-2/FREEZE` and `work/m1-exit-2/DATE`.
- Confirm the 4 run ids are free.
- Run preflight before each run.
- Linux flags: `--jobs 1 --cpus 8 --memory-gb 7 --timeout-minutes 60`. macOS: `--platform macos --timeout-minutes 60`.
- Background each run with `caffeinate -i`. Resume by re-issuing the identical command, never `--force`.
- `infra_error`: retry once, by deleting that cell directory.
- Commit each run as soon as it finishes.

**Durations (2026-10-11):** Linux about 1.5 h per pass (335 cells), macOS about 2.4 h per pass (69 cells, including guest boot). About **8 h** in total.

**Order:** both Linux runs, then quit Docker Desktop (`osascript -e 'quit app "Docker Desktop"'`, and wait until `docker info` fails), both macOS runs, then `open -a "Docker Desktop"`. Docker and the guest do not fit in 16 GiB together.

**Expected:** 335 Linux and 69 macOS cells per pass. Every Linux cell carries one of the five pinned image IDs; every macOS cell carries `ipsw-sha256:2f016638…`. If a Linux cell has no `image_id`, the §1.2 fix did not work: stop and investigate before committing.

## 3. Evaluation (ADR 0010 rules 2, 5)

1. One tools commit: `git diff <FREEZE> <run commit> -- tools corpus` empty for all 4; `tools_git_dirty: false`; manifest `bca2cc3e…` for all 4 (the script from the previous session: plan 2026-10-11 Task 12 Step 1).
2. `census compare runs/<D2> runs/<D2>-rerun`: restated A7. Record any `FAILED-BUILD DIFFERS` lines too.
3. `census compare runs/<D2>-macos runs/<D2>-macos-rerun`.
4. `census screen reproduce screen-2026-10-10 runs/<D2>-macos`.
5. **Do not run `census gate g2` as a verdict** (ADR 0009 / 0010 rule 5).

Steps 2 and 3 both SET-IDENTICAL → M1 exited. Anything else → investigate (ADR 0010 rule 6). Never re-run to get green.

## 4. Write-up

- ADR 0010 `## Results`: replace "Not yet run." with the actual values (run ids, freeze, times, the checks' output, outcome tables, any failed-build differences, and a "Not verified" section).
- `runs/README.md`: add the four runs and their compare lines; update "What these runs are not".
- ROADMAP M1 status line.
- Memory note `project_s_emit_screen_in_progress.md`.

## 5. Out of scope

M2; G2; re-selecting or re-screening; the SPI join; ADR 0005 (6.1 identifier wrapping, still open); classifying the unclassified Linux compile errors; `-j 1` builds (rejected in ADR 0010).
