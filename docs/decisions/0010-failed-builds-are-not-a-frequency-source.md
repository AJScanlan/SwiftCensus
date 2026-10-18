# ADR 0010 — A failed build's diagnostics are not a frequency source; A7 restated; M1 exit by fresh runs (pre-registered)

**Status:** **accepted by the owner (2026-10-18)**. Everything above "Results" is pre-registered: it is committed before the first cell of the fresh runs is built and is not edited after results are seen. If it turns out to be wrong, a new ADR says so.
**Date:** 2026-10-18
**Milestone:** M1 (exit)
**Amends:** ROADMAP A7 (how "set-identical" treats `build_failed` cells); `CellOutcome.buildFailed`'s "still data"
**Responds to:** ADR 0008 Results (A7 failed on both 2026-10-11 pairs)
**Relates to:** ADR 0007, 0008, 0009; ROADMAP A7, F6

## The result, which stands

**A7 as written failed on 2026-10-11.** `2026-10-11` vs `2026-10-11-rerun` and `2026-10-11-macos` vs `2026-10-11-macos-rerun` are **not set-identical**. Each pair differs in one `build_failed` cell. That record is not changed. The 2026-10-11 pairs are **not** re-evaluated under the rule below as a substitute M1 exit. Under that rule both would pass, because both differing cells are `build_failed` with equal outcomes. That is exactly why the rule is tested on fresh runs instead.

## Context: the mechanism, diagnosed from committed bytes

`customerio/customerio-ios` (macOS), traced from both passes' `build.log.gz` and `dia.tar.gz`. Nothing was re-run.

- Both passes fail on the **same first error**, a `SwiftCompile` of `Sources/Common/Util/DeviceInfo.swift` in target `CioInternalCommon`.
- When a compile task fails, the build stops starting new tasks. Tasks already running finish.
- In the first pass, Swift planning (dependency scanning) of four downstream targets (`CioMessagingInApp`, `CioMessagingPush`, `CioTrackingMigration`, `SharedTests`) had started when the failure landed. The log shows `Planning Swift` for them, and each left one `.dia`. Those scans produced the extra `dependency_scan_module_not_found` (`UIKit`) errors. In the re-run the failure landed first, those tasks never ran, and the failing target itself left 41 `.dia` files against the first pass's 82.
- So a failed build's diagnostics are whatever had run when it stopped, which depends on parallel scheduling.

`Quick/Nimble` (Linux 6.4) has the same shape: `build_failed` on both passes, 53 vs 68 `.dia` files, the first error in a different file on each pass, one side a strict superset of the other. It was **not** traced task by task the way customerio-ios was. It is consistent with the mechanism, not proven by it.

Why only 2 of 184 `build_failed` cells (Linux 174/175 identical, macOS 8/9) differed: a successful build runs every task, so scheduling cannot change what it reports. A failed one differs only when independent work is in flight when the error lands. That is rare, but it is structural: it is not removed by re-running.

`swift build` has `-j/--jobs` but no keep-going option. Serialising (`-j 1`) would make the truncation repeatable, not meaningful: "what ran before the first error" is a property of task order, not of the package. It was considered and rejected (owner, 2026-10-18).

## Decision

1. **A `build_failed` cell's diagnostics are not a frequency source.** They are still captured and committed (`diagnostics.json`, `build.log.gz`, `dia.tar.gz`), so they stay re-derivable, but no published count, ranking, `distinct_packages`, tally or coverage figure includes them, on either platform. A cell contributes diagnostics to frequencies only if its outcome is `built`. This matches what the screen (ADR 0007) and G2 (ADR 0008) already did.
2. **A7, restated.** Two runs on identical inputs are set-identical if and only if:
   - (a) they have the same set of cells;
   - (b) every cell's outcome is equal;
   - (c) every `built` cell's normalised multiset `(diagnostic_id, repo_relative_path, line, col, severity)` is equal.

   `build_failed` cells' multisets are still compared and their differences **reported** (count and cells), but they do not make a pair not set-identical. Nothing else in A7 changes.
3. **M1 is exited only by a fresh pair per platform**, at a new frozen tools commit, evaluated under rule 2: `<D2>` and `<D2>-rerun` (Linux), `<D2>-macos` and `<D2>-macos-rerun` (macOS), where `<D2>` is the date the new freeze is made. Same corpus (`corpus/packages.yaml` unchanged; manifest SHA-256 `bca2cc3ebd37ddda89d73d6c35cff47330613abd8155665c758472cd0ac285f4`); same pinned images and guest digest as ADR 0008; same run flags as ADR 0008. Preflight before every run.
4. **What the fresh tools commit may change, and nothing else:**
   - rule 2 in `RunComparison` (and wherever its verdict is used);
   - the `image_id` lookup that left 268 `2026-10-11-rerun` cells without one;
   - the `CellOutcome.buildFailed` doc comment, to say what rule 1 says.

   No change to the build invocation, the parser, attribution, or anything else that decides which diagnostics a `built` cell has.
5. **Not re-evaluated on the fresh runs:** G2. It is recorded as failed and investigated (ADR 0009); no substitute gate is scored. **Re-checked:** screen reproduction, `census screen reproduce screen-2026-10-10 runs/<D2>-macos` must be SET-IDENTICAL. Its 30 cells are all `built`, so rule 2 does not change what that check compares.
6. **If the fresh pair is not set-identical under rule 2:** investigated, never re-run to get green, and no further restatement without a new ADR. If an instrument bug is found and fixed, both passes of the affected pair are re-run at the fixed commit under new run ids (as ADR 0008).

## Power of the restated check (ADR 0009 rule 5)

Rule 2(c) compares diagnostics only for `built` cells. On the 2026-10-11 runs that is 60 of 69 cells on macOS (87%) and 124 of 335 on Linux (37%). Every cell's outcome is still compared, so a cell that flips between `built` and `build_failed` still fails A7. The Linux share is low because most packages do not build on Linux (ADR 0009). Linux gates nothing on a stratum selected on macOS, but it is half of the M1 exit, and this is the share of it that compares diagnostics.

## Known bias introduced

**Failed builds are censored from frequencies.** A package whose build fails contributes no diagnostics, even ones it really has. On macOS that is 9 of 69 corpus cells (2026-10-11). This bias already applied to `S-emit` membership (ADR 0007, Known bias 4) and is now general. The M3 write-up states it, with each platform's `build_failed` count.

## Results

Not yet run.
