# A7 restated, image-ID fix, fresh M1-exit runs: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Change only what ADR 0010 rule 4 allows, get the pre-freeze review, freeze, run a fresh pair per platform, and evaluate M1 exit under restated A7.

**Architecture:** Two code changes in `CensusRunner`. `RunComparison` reports `build_failed`-vs-`build_failed` multiset differences separately, so they no longer break set-identity. `MatrixRun` resolves image IDs through the fully qualified reference with a `docker images` fallback, and `execute` refuses to start when any ID is unresolved. Then the operational tasks run through `/matrix-run` and the review agents.

**Tech Stack:** Swift 6.0 package at `tools/`, swift-testing, bash 3.2 (`scripts/matrix-preflight.sh`), Docker Desktop, Lima guest.

**Spec:** `docs/superpowers/specs/2026-10-18-a7-restated-fresh-m1-runs.md` (owner-reviewed 2026-10-24). Governing ADR: `docs/decisions/0010-failed-builds-are-not-a-frequency-source.md`.

## Global Constraints

- The fresh tools commit changes only: rule 2 in `RunComparison` and wherever its verdict is used; the `image_id` lookup; the `CellOutcome.buildFailed` doc comment (ADR 0010 rule 4). No change to the build invocation, parser or attribution.
- Corpus unchanged: manifest SHA-256 `bca2cc3ebd37ddda89d73d6c35cff47330613abd8155665c758472cd0ac285f4`.
- Images and guest exactly as pinned in `scripts/matrix-preflight.sh` (ADR 0008). Nothing is pulled.
- Linux flags `--jobs 1 --cpus 8 --memory-gb 7 --timeout-minutes 60`; macOS `--platform macos --timeout-minutes 60`.
- Never `census run --force`. Resume by re-issuing the identical command. One `infra_error` retry, by deleting that cell directory.
- A failed check is investigated, never re-run to get green (ADR 0010 rule 6). G2 is not scored (rule 5).
- The 2026-10-11 pairs are never recorded as the M1 exit, even though they pass under the new rule.
- Tests: swift-testing. `swift test --package-path tools`: the total is the sum of the four "Test run with N tests" lines.
- `scripts/matrix-preflight.sh` stays bash 3.2: no associative arrays.

## Review Focus

1. **`inspect` and the listing disagree on an image's ID** (for example under the containerd image store). The fallback would then record an ID that matches no pin. Expected: both paths give the same ID. Pinned by the live check in Task 2 Step 8 (probed 2026-10-24: all five agree).
2. **Docker is down when `census run` starts.** Expected: the run refuses before any cell, naming the images, instead of recording `nil`. Pinned by `bothPathsFailingResolvesNothing` and `executeRefusesBeforeAnyCellWhenAnImageIsUnresolved` (Task 2).
3. **A near-miss tag in the listing**, such as `swift:6.4-jammy` beside `swift:6.4`, `<none>`, or a `localhost:5050/...` repository. Expected: only the exact repository and tag match. Pinned by `listingMatchesOnlyTheExactReference` (Task 2).
4. **A resumed run with no pending cells.** Expected: no lookup and no refusal. A partly resumed run must still refuse if a pending toolchain's image is unresolved. Pinned by `executeWithNothingPendingLooksUpNothing` (Task 2).
5. **A `build_failed` pair where only one side has diagnostics.** Expected: reported as failed-build-differing, not as an outcome mismatch or as identical, and every compared cell counted exactly once. Pinned by `failedBuildWithDiagnosticsOnOneSideOnlyIsReported` (Task 1).

The macOS paths pass `GuestVM.restoreImageDigest()`, which reads `tools/vm/census-macos.yaml` relative to the working directory. After Task 2, running `census` from another directory refuses instead of recording `nil`. That is intended: say so in the commit message.

---

### Task 1: A7 restated in `RunComparison`

**Files:**
- Modify: `tools/Sources/CensusRunner/Compare.swift` (`Report`, `compare`)
- Modify: `tools/Sources/census/Census.swift:296-308` (`printComparison`)
- Modify: `tools/Sources/census/Screen.swift:224-228` (`collect --with-verify` printer)
- Modify: `tools/Sources/CensusCore/CellRecord.swift:7` (`buildFailed` doc comment)
- Test: `tools/Tests/CensusRunnerTests/RunnerTests.swift` (`RunComparisonTests`)

**Interfaces:**
- Produces: `RunComparison.Report.failedBuildDiffering: [CellDifference]`. `isSetIdentical` is unchanged in form and ignores it by construction. `func failedBuildLine(_ d: RunComparison.CellDifference) -> String` in `Census.swift` returns `FAILED-BUILD DIFFERS (not gating, ADR 0010) <key>: -<n> +<m>` and is used by both printers.

- [ ] **Step 1: Write the failing tests** in `RunComparisonTests`, using the suite's existing `rec`/`cell`/`run` helpers:

```swift
@Test func failedBuildPairWithDifferingDiagnosticsIsSetIdenticalButReported() {
    let r = RunComparison.compare(run(cell("p", outcome: .buildFailed, [rec("x", line: 1)])),
                                  run(cell("p", outcome: .buildFailed, [rec("x", line: 2)])))
    #expect(r.isSetIdentical)
    #expect(r.failedBuildDiffering.map(\.key.packageId) == ["p"])
    #expect(r.differing.isEmpty && r.identical == 0)
}

@Test func failedBuildWithDiagnosticsOnOneSideOnlyIsReported() {
    let a = run(cell("p", outcome: .buildFailed, [rec("x")]), cell("q", [rec("y")]))
    let b = run(cell("p", outcome: .buildFailed, []), cell("q", [rec("y")]))
    let r = RunComparison.compare(a, b)
    #expect(r.isSetIdentical && r.failedBuildDiffering.count == 1 && r.identical == 1)
    #expect(r.cellsCompared == r.identical + r.differing.count + r.failedBuildDiffering.count
        + r.outcomeMismatches.count + r.noDiagnosticCells)
}

@Test func builtVersusBuildFailedIsAnOutcomeMismatch() {
    let r = RunComparison.compare(run(cell("p", [rec("x")])), run(cell("p", outcome: .buildFailed, [rec("x")])))
    #expect(!r.isSetIdentical && r.outcomeMismatches.count == 1 && r.failedBuildDiffering.isEmpty)
}

@Test func identicalFailedBuildsAreIdenticalAndNotReported() {
    let a = run(cell("p", outcome: .buildFailed, [rec("x")]))
    let r = RunComparison.compare(a, a)
    #expect(r.isSetIdentical && r.identical == 1 && r.failedBuildDiffering.isEmpty)
}
```

Also add `#expect(r.failedBuildDiffering.isEmpty)` to the existing `aMovedLineIsADifference`. That is the spec's "a `built` pair with differing diagnostics → not set-identical".

- [ ] **Step 2: Run them to verify they fail**

Run: `swift test --package-path tools --filter RunComparisonTests 2>&1 | tail -5`
Expected: compile failure, because `failedBuildDiffering` is not a member of `Report`.

- [ ] **Step 3: Implement.** Add `public var failedBuildDiffering: [CellDifference] = []` to `Report`, with a doc comment citing ADR 0010 rule 2. In `compare`, a non-empty difference goes to `failedBuildDiffering` when the (equal) outcome is `.buildFailed`, and to `differing` otherwise. Leave `isSetIdentical` as it is. Update the `Compare.swift` type comment to say A7 as restated by ADR 0010.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --package-path tools 2>&1 | grep -E "Test run with|failed"`
Expected: four "Test run with" lines, none failed.

- [ ] **Step 5: Print it.** Add `failedBuildLine` to `Census.swift`. In `printComparison`, append `; failed-build differs (not gating): <count>` to the summary line. After the `MULTISET DIFFERS` loop, print `failedBuildLine(d)` for each entry, with the same `only left` / `only right` detail (first 5). In `Screen.swift`'s `--with-verify` block, print `failedBuildLine(d)` for each entry after its `MULTISET DIFFERS` loop. Otherwise a `build_failed` difference there would now pass silently.

- [ ] **Step 6: Update the doc comment** on `CellOutcome.buildFailed` (`CellRecord.swift:7`) to: `Build exited non-zero after resolving. Its diagnostics are captured and committed, but are not a frequency source (ADR 0010 rule 1).` Leave the enum's type comment ("A failed cell is data, never a silent gap") as it is: still true.

- [ ] **Step 7: Real-data checks.** These only prove the code matches the rule. **None is the M1 exit.**

```bash
swift build -c release --package-path tools 2>&1 | tail -1
tools/.build/release/census compare runs/2026-10-11 runs/2026-10-11-rerun; echo "exit $?"
tools/.build/release/census compare runs/2026-10-11-macos runs/2026-10-11-macos-rerun; echo "exit $?"
tools/.build/release/census screen reproduce screen-2026-10-10 runs/2026-10-11-macos; echo "exit $?"
tools/.build/release/census screen collect screen-2026-10-10 --with-verify | grep -E "A7 over|DIFFERS"; git status --short screens/
```

Expected:
- Linux: `SET-IDENTICAL`, exit 0, exactly one `FAILED-BUILD DIFFERS (not gating, ADR 0010)` line, for `6.4` `Quick/Nimble`.
- macOS: the same, for `customerio/customerio-ios`.
- Reproduce: `SET-IDENTICAL` over 30 cells.
- Collect: `A7 over 47 stable emitters: 94 cells compared, 94 set-identical`, no `DIFFERS` lines, and an empty `git status`.

Any other result: stop and investigate.

- [ ] **Step 8: Commit**

```bash
git add tools/Sources/CensusRunner/Compare.swift tools/Sources/census/Census.swift tools/Sources/census/Screen.swift tools/Sources/CensusCore/CellRecord.swift tools/Tests/CensusRunnerTests/RunnerTests.swift
git commit -m "A7 restated (ADR 0010 rule 2): build_failed multiset differences are reported, not gating"
```

---

### Task 2: The `image_id` lookup refuses when unresolved

**Files:**
- Modify: `tools/Sources/CensusRunner/MatrixRun.swift:52-110` (`imageID`, `execute`)
- Modify: `tools/Sources/census/Census.swift:241,252`, `tools/Sources/census/Screen.swift:161,165` (`try await MatrixRun.execute`)
- Modify: `scripts/matrix-preflight.sh` (the image loop)
- Test: `tools/Tests/CensusRunnerTests/RunnerTests.swift` (new `ImageResolutionTests`; keep `ImageIDRetryTests`)

**Interfaces:**
- Produces, all in `MatrixRun`:
  - `public static func qualifiedReference(_ image: String) -> String`
  - `static func imageID(inListing listing: String, for image: String) -> String?`
  - `static func resolveImageID(_ image: String, attempts: Int = 3, pause: Duration = .seconds(1), inspect: (String) async -> String?, listing: () async -> String?) async -> String?`
  - `public static func imageID(_ image: String) async -> String?` (same signature; now built on `resolveImageID`)
  - `public struct UnresolvedImageError: Error, CustomStringConvertible { public var images: [String] }`
  - `execute(...)`, now `async throws`. Its `imageID` parameter keeps the type `@Sendable (String) async -> String?`.

- [ ] **Step 1: Write the failing tests** (`@Suite struct ImageResolutionTests`):

```swift
@Test func bareNamesQualifyToDockerHub() {
    #expect(MatrixRun.qualifiedReference("swift:6.4") == "docker.io/library/swift:6.4")
    #expect(MatrixRun.qualifiedReference("swiftlang/swift:nightly-main-jammy") == "docker.io/swiftlang/swift:nightly-main-jammy")
    #expect(MatrixRun.qualifiedReference("docker.io/library/swift:6.4") == "docker.io/library/swift:6.4")
    #expect(MatrixRun.qualifiedReference("localhost:5050/a/b:1") == "localhost:5050/a/b:1")
    #expect(MatrixRun.qualifiedReference("ghcr.io/a/b:1") == "ghcr.io/a/b:1")
}

@Test func listingMatchesOnlyTheExactReference() {
    let listing = """
    swift:6.4-jammy sha256:aaa
    swift:6.4 sha256:bbb
    swift:<none> sha256:ccc
    localhost:5050/swift:6.4 sha256:ddd
    swiftlang/swift:nightly-main-jammy sha256:eee
    """
    #expect(MatrixRun.imageID(inListing: listing, for: "swift:6.4") == "sha256:bbb")
    #expect(MatrixRun.imageID(inListing: listing, for: "docker.io/library/swift:6.4") == "sha256:bbb")
    #expect(MatrixRun.imageID(inListing: listing, for: "swiftlang/swift:nightly-main-jammy") == "sha256:eee")
    #expect(MatrixRun.imageID(inListing: listing, for: "swift:6.3") == nil)
}

@Test func inspectSuccessSkipsTheListing() async   // inspect returns "sha256:x" for the qualified ref; a listing closure that records calls is never called
@Test func inspectsTheQualifiedReference() async   // the inspect closure receives "docker.io/library/swift:6.1" for "swift:6.1"
@Test func inspectFailingFallsBackToTheListing() async   // inspect always nil (called `attempts` times), listing "swift:6.1 sha256:y" → "sha256:y"
@Test func bothPathsFailingResolvesNothing() async   // both nil → nil; pass attempts: 2, pause: .zero
@Test func executeRefusesBeforeAnyCellWhenAnImageIsUnresolved() async throws
@Test func executeWithNothingPendingLooksUpNothing() async throws
```

The two `execute` tests use a `FakeRunner: CellExecuting` (an actor-backed call counter, and `store` on a temp directory from `FileManager.default.temporaryDirectory`), with two `PlannedCell`s on different toolchain images.
- **Refusal:** the resolver returns nil for one image. Expect `#expect(throws: MatrixRun.UnresolvedImageError.self)`, zero `run` calls, and the error's `images` naming exactly that image.
- **Nothing pending:** first create `store.cellDirectory(toolchain:mode:slug:)` for every planned cell, with an empty `cell.json` in it (`hasCell` checks only that the file exists). Expect no throw, zero resolver calls and zero `run` calls.

- [ ] **Step 2: Run them to verify they fail**

Run: `swift test --package-path tools --filter ImageResolutionTests 2>&1 | tail -5`
Expected: compile failure on the missing members.

- [ ] **Step 3: Implement.**
  - `qualifiedReference`: leave the reference unchanged when its first `/` component contains `.` or `:`, or is `localhost`. Otherwise prefix `docker.io/library/` if there is no `/`, else `docker.io/`.
  - `imageID(inListing:for:)`: parse lines of `<repository>:<tag> <id>`, splitting at the last space, and skip `<none>` tags. Match on `qualifiedReference` of both sides.
  - `resolveImageID`: `firstResult` over `inspect(qualifiedReference(image))`. Then `firstResult` over `listing()` parsed with `imageID(inListing:for:)`. Both use `attempts` and `pause`.
  - `imageID(_:)`: `inspect` = `docker image inspect --format {{.Id}} <ref>`, one image per call. `listing` = `docker images --no-trunc --format "{{.Repository}}:{{.Tag}} {{.ID}}"`.
  - `UnresolvedImageError.description`: `no image ID for <images, comma-separated>: refusing to start the run (P3; spec 2026-10-18 §1.2)`.
  - `execute`: resolve every pending toolchain image before launching anything, and throw if any is nil. The map becomes `[String: String]`. Update the doc comments on both functions.

- [ ] **Step 4: Update the four callers** to `try await MatrixRun.execute(...)`.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --package-path tools 2>&1 | grep -E "Test run with|failed"`
Expected: four "Test run with" lines, none failed.

- [ ] **Step 6: Preflight resolves the same way.** In `scripts/matrix-preflight.sh`, add `qualify()`, a bash 3.2 `case` mirroring `qualifiedReference`. Each image is inspected as `"$(qualify "$image")"`, 3 tries 1 s apart. On failure, fall back to `docker images --no-trunc --format '{{.Repository}}:{{.Tag}} {{.ID}}'`, matching the line whose first field is exactly `$image`. Keep both failure messages and the `PREFLIGHT_ID_64` override.

- [ ] **Step 7: Commit**

```bash
git add tools/Sources/CensusRunner/MatrixRun.swift tools/Sources/census/Census.swift tools/Sources/census/Screen.swift scripts/matrix-preflight.sh tools/Tests/CensusRunnerTests/RunnerTests.swift
git commit -m "image_id: resolve via the qualified reference, fall back to the listing, refuse the run when unresolved (spec 2026-10-18 §1.2)"
```

In the message body, say that a macOS run from a directory without `tools/vm/census-macos.yaml` now refuses (Review Focus).

- [ ] **Step 8: Live checks** (Docker running, tree clean after the commit). Use the literal HEAD commit in place of `<HEAD>`:

```bash
scripts/matrix-preflight.sh linux <HEAD>; echo "exit $?"
PREFLIGHT_ID_64=sha256:0 scripts/matrix-preflight.sh linux <HEAD>; echo "exit $?"
docker images --no-trunc --format '{{.Repository}}:{{.Tag}} {{.ID}}'
```

Expected:
- `preflight OK (linux, …)`, exit 0.
- Then `preflight FAILED: swift:6.4 is sha256:4601bf61…; ADR 0008 pins sha256:0`, exit 1.
- The listing shows the five pinned IDs, matching what `inspect` returns for each qualified reference (Review Focus 1).

---

### Task 3: Pre-freeze review (spec §1.3)

- [ ] **Step 1:** Run the `freeze-reviewer` agent with base `553ba2fa217aeb3267fbd6b3b9925b3367dc210a` (the previous freeze; `tools/` is unchanged since), head `HEAD`, governing spec and ADR as above.
- [ ] **Step 2:** For each Critical or Important finding, fix it in its own commit, re-run the full test suite, and re-run the reviewer on the fix. Out-of-scope findings (outside ADR 0010 rule 4) are recorded for the owner, not fixed.
- [ ] **Step 3:** Gate: the reviewer's last line is `FREEZE: go`, **and** the owner approves the freeze. Show them the review. Do not freeze on the reviewer's word alone.

---

### Task 4: Freeze and the four runs (spec §2)

Campaign `m1-exit-2`, governing ADR `0010`. About 8 h in total. Each step is one `/matrix-run` invocation, and the skill carries the procedure: preflight, launch flags, `check-run.sh`, the single infra retry, commit and push.

- [ ] **Step 1:** `/matrix-run m1-exit-2 freeze`. Expected: `work/m1-exit-2/{FREEZE,DATE,ADR}` written (`ADR` = `0010`), release build OK, pushed, and all four run ids free.
- [ ] **Step 2:** `/matrix-run m1-exit-2 linux-a`. Expected: `check OK` (335 cells, five pinned image IDs, no `nil`), committed.
- [ ] **Step 3:** `/matrix-run m1-exit-2 linux-b`. Same expectations.
- [ ] **Step 4:** `/matrix-run m1-exit-2 macos-a`. Expected: Docker quit first, then `check OK` (69 cells, `ipsw-sha256:2f016638…` on every cell), committed.
- [ ] **Step 5:** `/matrix-run m1-exit-2 macos-b`. Same; then Docker restarted.

Any cell without `image_id` means the Task 2 fix did not work: stop before committing (spec §2).

---

### Task 5: Evaluate (spec §3)

Run every step even if an earlier one fails, and record each exit status. Outputs go to `work/m1-exit-2/check-*.txt` (untracked; quoted into ADR 0010 in Task 6). `<D2>` and `<FREEZE>` are the literal values from `work/m1-exit-2/`.

- [ ] **Step 1: One tools commit, one manifest.** For each of the four runs, read `tools_git_commit`, `tools_git_dirty` and `corpus_manifest_sha256` from `runs/<id>/run.json` with `jq`, then `git diff --quiet <FREEZE> <commit> -- tools corpus`. Write four lines to `check-0-freeze.txt`. Expected: each line unchanged, `dirty=false`, manifest `bca2cc3e…`.
- [ ] **Step 2:** `tools/.build/release/census compare runs/<D2> runs/<D2>-rerun > work/m1-exit-2/check-1-a7-linux.txt; echo "exit $?"`. Expected: `SET-IDENTICAL`, exit 0. Record any `FAILED-BUILD DIFFERS` lines too.
- [ ] **Step 3:** The same for `runs/<D2>-macos` and `runs/<D2>-macos-rerun`, into `check-2-a7-macos.txt`.
- [ ] **Step 4:** `tools/.build/release/census screen reproduce screen-2026-10-10 runs/<D2>-macos > work/m1-exit-2/check-3-reproduce.txt; echo "exit $?"`. Expected: `SET-IDENTICAL` over 30 cells.
- [ ] **Step 5: Verdict.** If Steps 2 and 3 are both SET-IDENTICAL, M1 is exited. Anything else: investigate from committed bytes, as ADR 0010 did for customerio-ios. Never re-run; no restatement without a new ADR. Do **not** run `census gate g2`.

---

### Task 6: Write-up (spec §4)

**Files:** `docs/decisions/0010-failed-builds-are-not-a-frequency-source.md` (`## Results` only), `runs/README.md`, `ROADMAP.md` (M1 status line), memory `project_s_emit_screen_in_progress.md`.

- [ ] **Step 1:** Replace ADR 0010's `Not yet run.` with: run ids, FREEZE, start times and durations, the four checks' output (`check-0`…`check-3`), an outcome table per run, every `FAILED-BUILD DIFFERS` line, a "Recorded deviations" section, and a "Not verified" section. Edit below `## Results` only: the `guard-pinned` hook asks before anything above it.
- [ ] **Step 2:** `runs/README.md`: add the four runs to the table and their compare lines, and update "What these runs are not".
- [ ] **Step 3:** `ROADMAP.md` M1 status line: exited (with the ADR 0010 pointer), or not, with the failing check.
- [ ] **Step 4:** Run the `numbers-auditor` agent on the ADR 0010 Results and the `runs/README.md` diff. Every MISMATCH or UNSOURCED is fixed before committing.
- [ ] **Step 5:** Commit the ADR Results alone, then README and ROADMAP together, and push.
- [ ] **Step 6:** Update the memory note to the new state (M1 exited or not, and what comes next). Do not start M2 in this session.
