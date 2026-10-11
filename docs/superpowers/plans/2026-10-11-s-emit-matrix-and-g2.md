# Full-corpus matrix runs, M1 exit and G2 — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Pre-register the G2 scoring rules (ADR 0008). Build `census gate g2`, `census screen reproduce` and a preflight script. Run the whole corpus twice on Linux (5 toolchains) and twice on macOS at one frozen tools commit. Then evaluate A7 (the M1 exit), screen reproduction and G2, and write up the results.

**Architecture:** The scoring logic is pure and lives in `CensusRunner`: `G2.swift` and `ScreenReproduction.swift`, tested with swift-testing on in-memory cells. The `census` executable gets thin commands that load committed runs through `RunStore` and call the pure layer. `scripts/matrix-preflight.sh` refuses to start a run whose inputs differ from ADR 0008's. The runs use the existing `census run` unchanged. Each run is committed as soon as it finishes.

**Tech Stack:** Swift 6 language mode (`tools/`, swift-tools-version 6.0), swift-testing, swift-argument-parser, Yams, Docker Desktop, Lima (`limactl`), bash 3.2 (macOS `/bin/bash`, so no associative arrays).

**Spec:** `docs/superpowers/specs/2026-10-11-s-emit-matrix-and-g2.md` (approved by the owner 2026-10-11). Read it together with this plan. Also read `CLAUDE.md`, `docs/decisions/0006`–`0007` (0007 including **Results**), `runs/README.md`, and §0 of `docs/superpowers/specs/2026-10-10-macos-screen.md`.

**Branch:** `m1/s-emit-matrix`, in the worktree `/Users/aj/iOS/SwiftCensus/.claude/worktrees/s-emit-matrix`. Do not create another branch.

**Conventions for every task:**
- Run every command from the worktree root `/Users/aj/iOS/SwiftCensus/.claude/worktrees/s-emit-matrix`. Never `cd` to `/Users/aj/iOS/SwiftCensus`.
- Build with `swift build --package-path tools`. Test with `swift test --package-path tools` (use `--filter <SuiteName>` for one suite).
- The debug CLI is `tools/.build/debug/census`. The runs use the release CLI `tools/.build/release/census` (built in Task 8).
- Commit messages end with a blank line followed by `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Code style follows the surrounding code: `///` comments that say *why*, kept short and dense; `public` API in `CensusRunner`; snake_case `CodingKeys`; no force-unwraps in production code.

## Global Constraints

- Build mode `strict-complete-v5` = `-strict-concurrency=complete` with `-swift-version 5` forced (ADR 0002). G2 scores **only** `strict-complete-v5` cells.
- G2 population: the 30 `stratum: S-emit` entries of `corpus/packages.yaml`. Denominator is always 30.
- "Emits": outcome `built` **and** ≥1 record with `attribution == .primary` and `severity != .note`. Every other outcome does not emit.
- Gating column `6.4` = `swift:6.4` @ `sha256:4601bf61dab9485a3e93087770b72d268737e945a5b000e2286b6cc48bb048b6`. G2 fails if `emits / 30 < 0.5`.
- Pinned images (never `docker pull` until the last run is committed):
  - `swift:6.1` @ `sha256:6e43114610e161e38ad41636ebcafd6940dc67dfab355eace3a0ca100b2263db`
  - `swift:6.2` @ `sha256:eccc7a97f9b9881d9659e2e788081fd7675f86d39793b51200bfb178398b3784`
  - `swift:6.3` @ `sha256:cd45c27b3abc42310c33cfaf3008b18156cbdc9187834c9617e8f43a26d2675c`
  - `swiftlang/swift:nightly-main-jammy` @ `sha256:191f78f3b9570ccdd382437b07ea0e8f98750206b96c71bad4f9515ec3aed4d2`
- Guest restore digest `sha256:2f016638293c3e641b8b25391a76fbc16563b3711915a5551cf8aa0f5598a5c1` (`tools/vm/census-macos.yaml`). Cells record it as `image_id: "ipsw-sha256:2f01…"`.
- Linux run flags, exactly as the last set-identical pair (`2026-10-04`): `--jobs 1 --cpus 8 --memory-gb 7 --timeout-minutes 60`. macOS: `--platform macos --timeout-minutes 60`.
- Run ids: `<D>`, `<D>-rerun`, `<D>-macos`, `<D>-macos-rerun`, where `<D>` is the UTC date Task 8 runs on. Expected cells: Linux 335 per pass, macOS 69 per pass.
- Docker Desktop and the macOS guest never run at the same time (16 GiB host).
- Never edit `corpus/packages.yaml`, `corpus/resolved/`, ADR 0007, or anything in ADR 0008 above `## Results` after Task 2's commit.

## Review Focus

These failure modes are implied by the spec but no unit test exercises them. Each one is pinned in the task that owns it:

1. **HEAD moves between runs.** Committing `runs/<D>` changes HEAD, so the four `run.json` files record different `tools_git_commit`s. A reasonable person expects "one tools commit" to mean tools/ and corpus/ are byte-unchanged from the freeze. They do not expect equal commit hashes. → Task 7's preflight diffs `tools corpus` against the freeze commit, and Task 12 step 1 checks every `run.json`.
2. **An `S-emit` entry with a `skip_reason`, or with no cell at all on 6.4.** It must make G2 *not evaluable*. It must not be silently dropped from the denominator. → Task 3 test `aSkippedEntryMakesItNotEvaluable`.
3. **Outcomes other than `built`/`build_failed` on the gating column** (`unsupported_tools_version`, `timeout`, `resolve_failed`). They score as not emitting and do not block evaluation. → Task 3 test `otherOutcomesDoNotEmitButAreEvaluable`.
4. **Screen cells carry `stratum: screen`; run cells carry `S-emit`.** The reproduction check must still compare them. It keys on toolchain/mode/package, never on stratum. → Task 5 fixtures use different strata on the two sides.
5. **A resumed run after an interruption (session limit, sleep).** Re-issuing the same `census run` command must only fill missing cells. `--force` must never be used. → Tasks 9–11 say so explicitly, and the infra retry deletes single cell directories instead.

---

### Task 1: Workspace baseline

**Files:**
- Create (untracked symlink): `work` → `/Users/aj/iOS/SwiftCensus/work`

**Interfaces:**
- Consumes: nothing.
- Produces: a worktree that shares the 7 GB source cache and SwiftPM mirror in the main checkout's `work/`, plus a green baseline test run.

- [ ] **Step 1: Link the shared working state**

`work/` is gitignored and holds `work/src` (source cache) and the SwiftPM mirror. Recreating it in the worktree would re-clone every package.

```bash
ln -s /Users/aj/iOS/SwiftCensus/work work
echo '/work' >> "$(git rev-parse --git-common-dir)/info/exclude"
git status --porcelain
```

Expected: `git status --porcelain` prints nothing. The symlink is excluded, and `.gitignore`'s `work/` pattern only matches directories.

- [ ] **Step 2: Baseline build and tests**

Run: `swift build --package-path tools && swift test --package-path tools 2>&1 | tail -5`
Expected: build succeeds, and the last lines report every test passing. Write down the test count, because Tasks 3–6 add to it.

- [ ] **Step 3: Baseline `compare` output, for the Task 6 refactor**

```bash
mkdir -p work/m1-exit
tools/.build/debug/census compare runs/2026-10-04 runs/2026-10-04-rerun > work/m1-exit/compare-baseline.txt; echo "exit $?"
tail -1 work/m1-exit/compare-baseline.txt
```

Expected: `exit 0`, last line `SET-IDENTICAL`.

No commit (nothing tracked changed).

---

### Task 2: ADR 0008 — pre-registration

**Files:**
- Create: `docs/decisions/0008-m1-exit-runs-and-g2.md`

**Interfaces:**
- Consumes: spec §2.
- Produces: the pre-registered values that Tasks 3–12 implement. The text above `## Results` is frozen once committed.

- [ ] **Step 1: Write the ADR**

```markdown
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
```

- [ ] **Step 2: Commit and push, and record the commit**

```bash
git add docs/decisions/0008-m1-exit-runs-and-g2.md
git commit -m "ADR 0008: pre-register G2 scoring and the M1-exit runs

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
git push -q
git rev-parse HEAD > work/m1-exit/ADR0008_COMMIT; cat work/m1-exit/ADR0008_COMMIT
```

Expected: a 40-character SHA. Task 13 cites it.

---

### Task 3: G2 scoring (pure)

**Files:**
- Create: `tools/Sources/CensusRunner/G2.swift`
- Test: `tools/Tests/CensusRunnerTests/G2Tests.swift`

**Interfaces:**
- Consumes: `CorpusManifest`, `CorpusPackage` (`.selection`, `.stratum`), `RunStore.CellKey`, `RunStore.LoadedCell`, `DiagnosticRecord`, `CellOutcome`.
- Produces:
  - `G2.populationSize: Int` (30), `G2.gatingToolchain: String` ("6.4"), `G2.threshold: Double` (0.5)
  - `G2.Tertile` (`head|middle|tail`), `G2.Verdict` (`pass|fail|not_evaluable`)
  - `G2.PackageResult { packageId, tertile: Tertile?, outcome: CellOutcome?, primaryNonNoteCount: Int, emits: Bool }`
  - `G2.TertileCount { emits, total }`
  - `G2.Column { toolchain, emits, emitsAnyOutcome, missing, infraError, byTertile: [String: TertileCount], packages }`
  - `G2.Report { verdict, reasons: [String], gatingToolchain, threshold, population, columns; var gating: Column? }`
  - `G2.primaryNonNoteCount(_ diagnostics: [DiagnosticRecord]) -> Int`
  - `G2.emits(_ cell: RunStore.LoadedCell) -> Bool`
  - `G2.tertile(of: CorpusPackage) -> Tertile?`
  - `G2.evaluate(manifest: CorpusManifest, cells: [RunStore.CellKey: RunStore.LoadedCell]) -> Report`

- [ ] **Step 1: Write the failing tests**

`tools/Tests/CensusRunnerTests/G2Tests.swift`:

```swift
import CensusCore
import Foundation
import Testing

@testable import CensusRunner

private func diag(severity: Severity = .warning, attribution: Attribution = .primary, line: Int = 1) -> DiagnosticRecord {
    DiagnosticRecord(id: "x", text: "t", severity: severity, group: nil, groupURL: nil, path: "Sources/A/a.swift",
                     line: line, col: 1, fixIts: 0, attribution: attribution, parent: nil)
}

/// 30 entries, 10 per tertile, ids o/p0 ... o/p29 (p0–p9 head, p10–p19 middle, p20–p29 tail).
private func emitEntry(_ i: Int) -> CorpusPackage {
    let tertile = ["head", "middle", "tail"][i / 10]
    return CorpusPackage(id: "o/p\(i)", url: "https://github.com/o/p\(i)", sha: String(repeating: "a", count: 40),
                         stratum: .emit, platforms: [.linuxSPM, .macosSPM],
                         selection: "seed=20261010 \(tertile)-tertile of 47 stable emitters; screen screen-2026-10-10 count 3")
}

private let population = (0..<30).map(emitEntry)

private func cell(_ id: String, toolchain: String = "6.4", _ outcome: CellOutcome = .built,
                  _ diags: [DiagnosticRecord] = [], mode: Mode = .strictCompleteV5,
                  platform: Platform = .linuxSPM, stratum: Stratum = .emit) -> (RunStore.CellKey, RunStore.LoadedCell) {
    let r = CellRecord(packageId: id, sha: String(repeating: "a", count: 40), stratum: stratum, toolchain: toolchain,
                       mode: mode, platform: platform, outcome: outcome, exitCode: 0, startedAt: "", durationSeconds: 0,
                       invocation: [], image: "")
    return (RunStore.CellKey(toolchain: toolchain, mode: mode, packageId: id),
            RunStore.LoadedCell(record: r, diagnostics: diags, directory: URL(fileURLWithPath: "/")))
}

/// Every one of the 30 has a `built` cell on `toolchain`; the first `n` (by index) carry one primary warning.
private func column(emitting n: Int, toolchain: String = "6.4") -> [RunStore.CellKey: RunStore.LoadedCell] {
    Dictionary(uniqueKeysWithValues: (0..<30).map { i in
        cell("o/p\(i)", toolchain: toolchain, .built, i < n ? [diag()] : [])
    })
}

private func with(_ base: [RunStore.CellKey: RunStore.LoadedCell],
                  _ cells: (RunStore.CellKey, RunStore.LoadedCell)...) -> [RunStore.CellKey: RunStore.LoadedCell] {
    base.merging(cells, uniquingKeysWith: { _, new in new })
}

@Suite struct G2ScoringTests {
    @Test func fifteenOfThirtyPasses() {
        let r = G2.evaluate(manifest: CorpusManifest(packages: population), cells: column(emitting: 15))
        #expect(r.verdict == .pass)
        #expect(r.gating?.emits == 15)
        #expect(r.reasons.isEmpty)
    }

    @Test func fourteenOfThirtyFails() {
        let r = G2.evaluate(manifest: CorpusManifest(packages: population), cells: column(emitting: 14))
        #expect(r.verdict == .fail)
        #expect(r.gating?.emits == 14)
    }

    @Test func buildFailedWithPrimaryErrorsDoesNotEmitButCountsAnyOutcome() {
        let cells = with(column(emitting: 15), cell("o/p20", .buildFailed, [diag(severity: .error)]))
        let r = G2.evaluate(manifest: CorpusManifest(packages: population), cells: cells)
        #expect(r.gating?.emits == 15)
        #expect(r.gating?.emitsAnyOutcome == 16)
        #expect(r.gating?.packages.first { $0.packageId == "o/p20" }?.emits == false)
    }

    @Test func notesAndNonPrimaryDoNotEmit() {
        let cells = with(column(emitting: 15),
                         cell("o/p20", .built, [diag(severity: .note)]),
                         cell("o/p21", .built, [diag(attribution: .transitive)]),
                         cell("o/p22", .built, [diag(attribution: .generated)]),
                         cell("o/p23", .built, [diag(attribution: .external)]))
        let r = G2.evaluate(manifest: CorpusManifest(packages: population), cells: cells)
        #expect(r.gating?.emits == 15)
        #expect(r.gating?.emitsAnyOutcome == 15)
    }

    @Test func otherOutcomesDoNotEmitButAreEvaluable() {
        let cells = with(column(emitting: 15),
                         cell("o/p20", .timeout), cell("o/p21", .unsupportedToolsVersion), cell("o/p22", .resolveFailed))
        let r = G2.evaluate(manifest: CorpusManifest(packages: population), cells: cells)
        #expect(r.verdict == .pass)
        #expect(r.gating?.packages.first { $0.packageId == "o/p21" }?.outcome == .unsupportedToolsVersion)
    }

    @Test func aMissingGatingCellIsNotEvaluable() {
        var cells = column(emitting: 30)
        cells[RunStore.CellKey(toolchain: "6.4", mode: .strictCompleteV5, packageId: "o/p29")] = nil
        let r = G2.evaluate(manifest: CorpusManifest(packages: population), cells: cells)
        #expect(r.verdict == .notEvaluable)
        #expect(r.gating?.missing == 1)
    }

    @Test func anInfraErrorGatingCellIsNotEvaluable() {
        let cells = with(column(emitting: 30), cell("o/p29", .infraError))
        let r = G2.evaluate(manifest: CorpusManifest(packages: population), cells: cells)
        #expect(r.verdict == .notEvaluable)
        #expect(r.gating?.infraError == 1)
    }

    @Test func aSkippedEntryMakesItNotEvaluable() {
        var skipped = population
        skipped[29].skipReason = "unresolvable"
        var cells = column(emitting: 30)
        cells[RunStore.CellKey(toolchain: "6.4", mode: .strictCompleteV5, packageId: "o/p29")] = nil
        let r = G2.evaluate(manifest: CorpusManifest(packages: skipped), cells: cells)
        #expect(r.verdict == .notEvaluable)
        #expect(r.population == 30)
    }

    @Test func gapsOnANonGatingColumnDoNotBlock() {
        var nightly = column(emitting: 10, toolchain: "nightly")
        nightly[RunStore.CellKey(toolchain: "nightly", mode: .strictCompleteV5, packageId: "o/p0")] = nil
        let r = G2.evaluate(manifest: CorpusManifest(packages: population),
                            cells: column(emitting: 20).merging(nightly, uniquingKeysWith: { a, _ in a }))
        #expect(r.verdict == .pass)
        let n = r.columns.first { $0.toolchain == "nightly" }
        #expect(n?.missing == 1)
        #expect(n?.emits == 9)
        #expect(r.columns.map(\.toolchain) == ["6.4", "nightly"])
    }

    @Test func otherStrataAndOtherModesAreIgnored() {
        let control = CorpusPackage(id: "c/ctl", url: "https://github.com/c/ctl", sha: String(repeating: "b", count: 40),
                                    stratum: .control, platforms: [.linuxSPM], selection: "t")
        let cells = with(column(emitting: 14),
                         cell("c/ctl", .built, [diag()], stratum: .control),
                         cell("o/p20", .built, [diag()], mode: .strictCompleteDeclared))
        let r = G2.evaluate(manifest: CorpusManifest(packages: population + [control]), cells: cells)
        #expect(r.verdict == .fail)
        #expect(r.gating?.emits == 14)
        #expect(r.population == 30)
    }

    @Test func aPopulationOtherThanThirtyIsNotEvaluable() {
        let r = G2.evaluate(manifest: CorpusManifest(packages: Array(population.prefix(29))), cells: column(emitting: 29))
        #expect(r.verdict == .notEvaluable)
    }

    @Test func anEntryWithoutATertileIsNotEvaluable() {
        var untagged = population
        untagged[0].selection = "hand-picked"
        let r = G2.evaluate(manifest: CorpusManifest(packages: untagged), cells: column(emitting: 30))
        #expect(r.verdict == .notEvaluable)
    }

    @Test func aMacOSCellIsNotEvaluable() {
        let cells = with(column(emitting: 30), cell("o/p0", .built, [diag()], platform: .macosSPM))
        let r = G2.evaluate(manifest: CorpusManifest(packages: population), cells: cells)
        #expect(r.verdict == .notEvaluable)
    }

    @Test func countsPerTertile() {
        // p0–p9 head all emit, p10–p14 middle emit, tail none.
        let r = G2.evaluate(manifest: CorpusManifest(packages: population), cells: column(emitting: 15))
        #expect(r.gating?.byTertile["head"] == G2.TertileCount(emits: 10, total: 10))
        #expect(r.gating?.byTertile["middle"] == G2.TertileCount(emits: 5, total: 10))
        #expect(r.gating?.byTertile["tail"] == G2.TertileCount(emits: 0, total: 10))
    }

    @Test func reportEncodesSnakeCase() throws {
        let r = G2.evaluate(manifest: CorpusManifest(packages: population), cells: column(emitting: 15))
        let json = String(decoding: try RunStore.encoder().encode(r), as: UTF8.self)
        #expect(json.contains("\"emits_any_outcome\""))
        #expect(json.contains("\"gating_toolchain\" : \"6.4\""))
        #expect(json.contains("\"verdict\" : \"pass\""))
        #expect(try JSONDecoder().decode(G2.Report.self, from: Data(json.utf8)) == r)
    }
}
```

- [ ] **Step 2: Run the tests and confirm they fail**

Run: `swift test --package-path tools --filter G2ScoringTests 2>&1 | tail -5`
Expected: compile failure, `cannot find 'G2' in scope`.

- [ ] **Step 3: Implement**

`tools/Sources/CensusRunner/G2.swift`:

```swift
import CensusCore
import Foundation

/// ROADMAP G2 as redefined by ADR 0007 D8, scored by the rules ADR 0008 pre-registers: of the 30 `S-emit` entries, how
/// many emit on Linux 6.4. Pure: it scores cells `RunStore` has already loaded.
public enum G2 {
    /// ADR 0008. Pre-registered: changing one is a new ADR, never an edit.
    public static let populationSize = 30
    public static let gatingToolchain = "6.4"
    public static let threshold = 0.5

    public enum Tertile: String, Codable, Sendable, CaseIterable { case head, middle, tail }

    public enum Verdict: String, Codable, Sendable {
        case pass, fail
        case notEvaluable = "not_evaluable"
    }

    public struct PackageResult: Codable, Equatable, Sendable {
        public var packageId: String
        public var tertile: Tertile?
        /// Nil when the run has no cell for this package on this column.
        public var outcome: CellOutcome?
        public var primaryNonNoteCount: Int
        public var emits: Bool

        enum CodingKeys: String, CodingKey {
            case packageId = "package_id", tertile, outcome
            case primaryNonNoteCount = "primary_non_note_count", emits
        }
    }

    public struct TertileCount: Codable, Equatable, Sendable {
        public var emits = 0
        public var total = 0
    }

    public struct Column: Codable, Equatable, Sendable {
        public var toolchain: String
        public var emits = 0
        /// Non-gating: ≥1 primary non-note diagnostic whatever the outcome, so a `build_failed` cell's errors count.
        public var emitsAnyOutcome = 0
        public var missing = 0
        public var infraError = 0
        public var byTertile: [String: TertileCount] = [:]
        public var packages: [PackageResult] = []

        enum CodingKeys: String, CodingKey {
            case toolchain, emits, emitsAnyOutcome = "emits_any_outcome", missing, infraError = "infra_error"
            case byTertile = "by_tertile", packages
        }
    }

    public struct Report: Codable, Equatable, Sendable {
        public var verdict: Verdict
        /// Why the verdict is `not_evaluable`; empty otherwise.
        public var reasons: [String]
        public var gatingToolchain: String
        public var threshold: Double
        public var population: Int
        public var columns: [Column]

        enum CodingKeys: String, CodingKey {
            case verdict, reasons, gatingToolchain = "gating_toolchain", threshold, population, columns
        }

        public var gating: Column? { columns.first { $0.toolchain == gatingToolchain } }
    }

    /// ADR 0007 D1's record filter: primary attribution, any severity but note.
    public static func primaryNonNoteCount(_ diagnostics: [DiagnosticRecord]) -> Int {
        diagnostics.filter { $0.attribution == .primary && $0.severity != .note }.count
    }

    /// ADR 0008: only a `built` cell emits. A Linux `build_failed` cell's primary errors are mostly missing Apple modules,
    /// which strict checking did not cause.
    public static func emits(_ cell: RunStore.LoadedCell) -> Bool {
        cell.record.outcome == .built && primaryNonNoteCount(cell.diagnostics) > 0
    }

    /// Read from the entry's `selection`, which `select emit --from-screen` writes as "… head-tertile of 47 …".
    public static func tertile(of package: CorpusPackage) -> Tertile? {
        Tertile.allCases.first { package.selection.contains("\($0.rawValue)-tertile") }
    }

    public static func evaluate(manifest: CorpusManifest,
                                cells: [RunStore.CellKey: RunStore.LoadedCell]) -> Report {
        let population = manifest.packages.filter { $0.stratum == .emit }.sorted { $0.id < $1.id }
        let ids = Set(population.map(\.id))
        let scored = cells.filter { ids.contains($0.key.packageId) && $0.key.mode == .strictCompleteV5 }

        var reasons: [String] = []
        if population.count != populationSize {
            reasons.append("the manifest has \(population.count) S-emit entries; ADR 0008 fixes \(populationSize)")
        }
        let untagged = population.filter { tertile(of: $0) == nil }.map(\.id)
        if !untagged.isEmpty { reasons.append("no tertile in selection: \(untagged.joined(separator: ", "))") }
        let foreign = scored.values.filter { $0.record.platform != .linuxSPM }.count
        if foreign > 0 { reasons.append("\(foreign) S-emit cells are not linux-spm; G2 is scored on Linux only") }

        let toolchains = Set(scored.keys.map(\.toolchain)).union([gatingToolchain]).sorted()
        let columns = toolchains.map { column($0, population: population, cells: scored) }
        let gating = columns.first { $0.toolchain == gatingToolchain } ?? Column(toolchain: gatingToolchain)
        if gating.missing > 0 { reasons.append("\(gating.missing) S-emit cells missing on \(gatingToolchain)") }
        if gating.infraError > 0 { reasons.append("\(gating.infraError) S-emit cells are infra_error on \(gatingToolchain)") }

        let verdict: Verdict = !reasons.isEmpty ? .notEvaluable
            : Double(gating.emits) / Double(populationSize) < threshold ? .fail : .pass
        return Report(verdict: verdict, reasons: reasons, gatingToolchain: gatingToolchain, threshold: threshold,
                      population: population.count, columns: columns)
    }

    static func column(_ toolchain: String, population: [CorpusPackage],
                       cells: [RunStore.CellKey: RunStore.LoadedCell]) -> Column {
        var c = Column(toolchain: toolchain)
        for p in population {
            let cell = cells[RunStore.CellKey(toolchain: toolchain, mode: .strictCompleteV5, packageId: p.id)]
            let outcome = cell?.record.outcome
            let count = cell.map { primaryNonNoteCount($0.diagnostics) } ?? 0
            let emitting = cell.map { emits($0) } ?? false
            let t = tertile(of: p)
            if outcome == nil { c.missing += 1 }
            if outcome == .infraError { c.infraError += 1 }
            if emitting { c.emits += 1 }
            if count > 0, outcome != .infraError { c.emitsAnyOutcome += 1 }
            if let t {
                c.byTertile[t.rawValue, default: TertileCount()].total += 1
                if emitting { c.byTertile[t.rawValue, default: TertileCount()].emits += 1 }
            }
            c.packages.append(PackageResult(packageId: p.id, tertile: t, outcome: outcome,
                                            primaryNonNoteCount: count, emits: emitting))
        }
        return c
    }
}
```

- [ ] **Step 4: Run the tests and confirm they pass**

Run: `swift test --package-path tools --filter G2ScoringTests 2>&1 | tail -5`
Expected: all 15 tests in `G2ScoringTests` pass.

- [ ] **Step 5: Commit**

```bash
git add tools/Sources/CensusRunner/G2.swift tools/Tests/CensusRunnerTests/G2Tests.swift
git commit -m "G2 scoring as pre-registered in ADR 0008

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: `census gate g2`

**Files:**
- Modify: `tools/Sources/CensusRunner/G2.swift` (add `render`, `fraction`, `percent`)
- Create: `tools/Sources/census/Gate.swift`
- Modify: `tools/Sources/census/Census.swift:13` (register `Gate.self`)
- Test: `tools/Tests/CensusRunnerTests/G2Tests.swift` (add `G2RenderTests`)

**Interfaces:**
- Consumes: `G2.evaluate`, `G2.Report` (Task 3); `CorpusOptions.paths.loadManifest()`; `RunStore(root:).loadCells()`; `RunStore.write(_:to:)`.
- Produces: `G2.render(_ report: Report) -> [String]`; the CLI `census gate g2 [--manifest m] <run-directory> [--json path]`, which exits 0 on pass, 1 on fail and 2 when not evaluable.

- [ ] **Step 1: Write the failing tests** (append to `G2Tests.swift`)

```swift
@Suite struct G2RenderTests {
    @Test func endsWithTheVerdictAndMarksTheGatingColumn() {
        let pass = G2.render(G2.evaluate(manifest: CorpusManifest(packages: population), cells: column(emitting: 15)))
        #expect(pass.last == "G2 PASS")
        #expect(pass.contains { $0.hasPrefix("6.4 [gating]: 15/30 emit (50.0%)") })
        let fail = G2.render(G2.evaluate(manifest: CorpusManifest(packages: population), cells: column(emitting: 14)))
        #expect(fail.last == "G2 FAIL")
        let none = G2.render(G2.evaluate(manifest: CorpusManifest(packages: population), cells: [:]))
        #expect(none.last == "G2 NOT EVALUABLE")
        #expect(none.contains { $0.hasPrefix("not evaluable: 30 S-emit cells missing on 6.4") })
    }

    @Test func listsEveryNonEmittingGatingPackageWithItsOutcome() {
        let cells = with(column(emitting: 29), cell("o/p29", .buildFailed, [diag(severity: .error)]))
        let lines = G2.render(G2.evaluate(manifest: CorpusManifest(packages: population), cells: cells))
        #expect(lines.contains("  not emitting on 6.4: o/p29 [tail] build_failed, primary non-note 1"))
        #expect(lines.filter { $0.hasPrefix("  not emitting") }.count == 1)
    }
}
```

- [ ] **Step 2: Run the tests and confirm they fail**

Run: `swift test --package-path tools --filter G2RenderTests 2>&1 | tail -5`
Expected: compile failure, `type 'G2' has no member 'render'`.

- [ ] **Step 3: Implement `render`** (append inside `public enum G2` in `G2.swift`)

```swift
    /// What `census gate g2` prints. The last line is always the verdict.
    public static func render(_ r: Report) -> [String] {
        var out = ["G2 (ADR 0008): gating column \(r.gatingToolchain), fails below \(percent(r.threshold)), "
            + "population \(r.population)"]
        for c in r.columns {
            let tertiles = Tertile.allCases.map { t in
                let n = c.byTertile[t.rawValue] ?? TertileCount()
                return "\(t.rawValue) \(n.emits)/\(n.total)"
            }.joined(separator: ", ")
            out.append("\(c.toolchain)\(c.toolchain == r.gatingToolchain ? " [gating]" : ""): "
                + "\(c.emits)/\(r.population) emit (\(percent(fraction(c.emits, r.population)))); "
                + "any outcome \(c.emitsAnyOutcome)/\(r.population) (non-gating); \(tertiles); "
                + "missing \(c.missing), infra_error \(c.infraError)")
        }
        if let g = r.gating {
            for p in g.packages where !p.emits {
                out.append("  not emitting on \(g.toolchain): \(p.packageId) [\(p.tertile?.rawValue ?? "?")] "
                    + "\(p.outcome?.rawValue ?? "missing"), primary non-note \(p.primaryNonNoteCount)")
            }
        }
        for reason in r.reasons { out.append("not evaluable: \(reason)") }
        let verdict: String = switch r.verdict {
        case .pass: "G2 PASS"
        case .fail: "G2 FAIL"
        case .notEvaluable: "G2 NOT EVALUABLE"
        }
        out.append(verdict)
        return out
    }

    static func fraction(_ n: Int, _ d: Int) -> Double { d == 0 ? 0 : Double(n) / Double(d) }
    static func percent(_ x: Double) -> String { String(format: "%.1f%%", 100 * x) }
```

- [ ] **Step 4: Run the tests and confirm they pass**

Run: `swift test --package-path tools --filter G2 2>&1 | tail -5`
Expected: `G2ScoringTests` and `G2RenderTests` all pass.

- [ ] **Step 5: Add the command**

`tools/Sources/census/Gate.swift`:

```swift
import ArgumentParser
import CensusCore
import CensusRunner
import Foundation

struct Gate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "ROADMAP §4 decision gates, evaluated from committed runs.",
        subcommands: [G2Command.self])
}

extension Gate {
    struct G2Command: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "g2",
            abstract: "G2 (ADR 0007 D8, scored per ADR 0008): do the 30 S-emit entries emit on Linux 6.4?",
            discussion: "Exit 0: passes. Exit 1: fails. Exit 2: not evaluable (a 6.4 S-emit cell missing or infra_error, "
                + "a non-Linux S-emit cell, or a population other than 30). Score the first pass, never the re-run.")

        @OptionGroup var corpus: CorpusOptions
        @Argument(help: "Linux run directory, e.g. runs/2026-10-11.") var runDirectory: String
        @Option(name: .long, help: "Also write the report as JSON here, e.g. runs/2026-10-11/g2.json.") var json: String?

        func run() async throws {
            let report = G2.evaluate(manifest: try corpus.paths.loadManifest(),
                                     cells: try RunStore(root: URL(fileURLWithPath: runDirectory)).loadCells())
            for line in G2.render(report) { print(line) }
            if let json { try RunStore(root: URL(fileURLWithPath: ".")).write(report, to: URL(fileURLWithPath: json)) }
            switch report.verdict {
            case .pass: return
            case .fail: throw ExitCode.failure
            case .notEvaluable: throw ExitCode(2)
            }
        }
    }
}
```

In `tools/Sources/census/Census.swift`, add `Gate.self` to the subcommand list:

```swift
        subcommands: [Validate.self, Select.self, Resolve.self, Run.self, Scan.self, Compare.self, Parse.self, Reclassify.self, ScreenCommand.self, Gate.self])
```

- [ ] **Step 6: Smoke test against a real run that predates `S-emit`**

Run: `swift build --package-path tools && tools/.build/debug/census gate g2 runs/2026-10-04; echo "exit $?"`
Expected: the column lines, then `not evaluable: 30 S-emit cells missing on 6.4`, `G2 NOT EVALUABLE`, `exit 2`.

- [ ] **Step 7: Commit**

```bash
git add tools/Sources/CensusRunner/G2.swift tools/Tests/CensusRunnerTests/G2Tests.swift tools/Sources/census/Gate.swift tools/Sources/census/Census.swift
git commit -m "census gate g2: exit 0 pass, 1 fail, 2 not evaluable

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: Screen reproduction (pure)

**Files:**
- Create: `tools/Sources/CensusRunner/ScreenReproduction.swift`
- Test: `tools/Tests/CensusRunnerTests/ScreenReproductionTests.swift`

**Interfaces:**
- Consumes: `RunComparison.compare(_:_:) -> RunComparison.Report`, `Screen.toolchain` (`Toolchain.macOSXcode`, name `xcode-27.0`), `RunStore.CellKey`, `RunStore.LoadedCell`, `CellRecord.sha`, `.resolvedFileSHA256`, `.imageID`, `.xcodeBuild`.
- Produces:
  - `ScreenReproduction.InputMismatch { packageId, field, screen, run }` (`CustomStringConvertible`)
  - `ScreenReproduction.Result { inputMismatches, comparison: RunComparison.Report?, ignoredScreenCells, ignoredRunCells; var isReproduced: Bool }`
  - `ScreenReproduction.check(packages: [CorpusPackage], screenCells: [RunStore.CellKey: RunStore.LoadedCell], runCells: [RunStore.CellKey: RunStore.LoadedCell]) -> Result`

- [ ] **Step 1: Write the failing tests**

`tools/Tests/CensusRunnerTests/ScreenReproductionTests.swift`:

```swift
import CensusCore
import Foundation
import Testing

@testable import CensusRunner

private let sha = String(repeating: "a", count: 40)

private func diag(_ line: Int) -> DiagnosticRecord {
    DiagnosticRecord(id: "x", text: "t", severity: .warning, group: nil, groupURL: nil, path: "Sources/A/a.swift",
                     line: line, col: 1, fixIts: 0, attribution: .primary, parent: nil)
}

private func entry(_ id: String) -> CorpusPackage {
    CorpusPackage(id: id, url: "https://github.com/\(id)", sha: sha, stratum: .emit, platforms: [.linuxSPM, .macosSPM],
                  selection: "t", screenId: "screen-2026-10-10", screenCountAtSelection: 1)
}

/// Screen cells carry `stratum: screen` and run cells `S-emit` (Review Focus 4): the check must not care.
private func cell(_ id: String, _ diags: [DiagnosticRecord], stratum: Stratum, mode: Mode = .strictCompleteV5,
                  sha cellSHA: String = sha, resolved: String? = "r1",
                  image: String? = "ipsw-sha256:g", xcode: String? = "27A266a") -> (RunStore.CellKey, RunStore.LoadedCell) {
    var r = CellRecord(packageId: id, sha: cellSHA, stratum: stratum, toolchain: "xcode-27.0", mode: mode,
                       platform: .macosSPM, outcome: .built, exitCode: 0, startedAt: "", durationSeconds: 0,
                       invocation: [], image: "lima:census-macos")
    r.resolvedFileSHA256 = resolved
    r.imageID = image
    r.xcodeBuild = xcode
    return (RunStore.CellKey(toolchain: "xcode-27.0", mode: mode, packageId: id),
            RunStore.LoadedCell(record: r, diagnostics: diags, directory: URL(fileURLWithPath: "/")))
}

private func cells(_ c: (RunStore.CellKey, RunStore.LoadedCell)...) -> [RunStore.CellKey: RunStore.LoadedCell] {
    Dictionary(uniqueKeysWithValues: c)
}

@Suite struct ScreenReproductionTests {
    let packages = [entry("o/a"), entry("o/b")]

    @Test func identicalCellsReproduceAndExtrasAreIgnored() {
        let screen = cells(cell("o/a", [diag(1)], stratum: .screen), cell("o/b", [], stratum: .screen),
                           cell("o/a", [diag(1)], stratum: .screen, mode: .minimalV5),
                           cell("x/not-selected", [diag(9)], stratum: .screen))
        let run = cells(cell("o/a", [diag(1)], stratum: .emit), cell("o/b", [], stratum: .emit),
                        cell("o/a", [diag(1)], stratum: .emit, mode: .strictCompleteDeclared))
        let r = ScreenReproduction.check(packages: packages, screenCells: screen, runCells: run)
        #expect(r.isReproduced)
        #expect(r.comparison?.cellsCompared == 2)
        #expect(r.ignoredScreenCells == 2)
        #expect(r.ignoredRunCells == 1)
    }

    @Test func aDifferingDiagnosticDoesNotReproduce() {
        let r = ScreenReproduction.check(packages: packages,
                                         screenCells: cells(cell("o/a", [diag(1)], stratum: .screen), cell("o/b", [], stratum: .screen)),
                                         runCells: cells(cell("o/a", [diag(2)], stratum: .emit), cell("o/b", [], stratum: .emit)))
        #expect(!r.isReproduced)
        #expect(r.comparison?.differing.count == 1)
    }

    @Test func aCellMissingFromTheRunDoesNotReproduce() {
        let r = ScreenReproduction.check(packages: packages,
                                         screenCells: cells(cell("o/a", [], stratum: .screen), cell("o/b", [], stratum: .screen)),
                                         runCells: cells(cell("o/a", [], stratum: .emit)))
        #expect(!r.isReproduced)
        #expect(r.comparison?.onlyInLeft.map(\.packageId) == ["o/b"])
    }

    @Test func differentInputsAreRefusedNotCompared() {
        let other = String(repeating: "b", count: 40)
        for run in [cells(cell("o/a", [], stratum: .emit, sha: other)),
                    cells(cell("o/a", [], stratum: .emit, resolved: "r2")),
                    cells(cell("o/a", [], stratum: .emit, image: "ipsw-sha256:other")),
                    cells(cell("o/a", [], stratum: .emit, xcode: "27B1"))] {
            let r = ScreenReproduction.check(packages: [entry("o/a")],
                                             screenCells: cells(cell("o/a", [], stratum: .screen)), runCells: run)
            #expect(!r.isReproduced)
            #expect(r.comparison == nil)
            #expect(r.inputMismatches.count == 1)
        }
    }

    @Test func anUnrecordedResolvedHashIsAMismatch() {
        let r = ScreenReproduction.check(packages: [entry("o/a")],
                                         screenCells: cells(cell("o/a", [], stratum: .screen, resolved: nil)),
                                         runCells: cells(cell("o/a", [], stratum: .emit, resolved: nil)))
        #expect(r.comparison == nil)
        #expect(r.inputMismatches.first?.field == "resolved_file_sha256")
    }
}
```

- [ ] **Step 2: Run the tests and confirm they fail**

Run: `swift test --package-path tools --filter ScreenReproductionTests 2>&1 | tail -5`
Expected: compile failure, `cannot find 'ScreenReproduction' in scope`.

- [ ] **Step 3: Implement**

`tools/Sources/CensusRunner/ScreenReproduction.swift`:

```swift
import CensusCore
import Foundation

/// Spec 2026-10-11 §3.2. A macOS run's `S-emit` `strict-complete-v5` cells were built from the same SHA, resolved file,
/// guest image and Xcode as their screen pass-1 cells, so they must be A7 set-identical to them. If they are not, the
/// measurement that selected `S-emit` does not reproduce. Keys ignore stratum: screen cells say `screen`, runs `S-emit`.
public enum ScreenReproduction {
    public struct InputMismatch: Equatable, Sendable, CustomStringConvertible {
        public var packageId: String
        public var field: String
        public var screen: String
        public var run: String
        public var description: String { "\(packageId): \(field) differs (screen \(screen), run \(run))" }
    }

    public struct Result: Sendable {
        /// Non-empty means the two sides were built from different inputs, so nothing was compared.
        public var inputMismatches: [InputMismatch]
        public var comparison: RunComparison.Report?
        /// Cells outside the `S-emit` × `strict-complete-v5` keys, ignored on each side.
        public var ignoredScreenCells: Int
        public var ignoredRunCells: Int
        public var isReproduced: Bool { inputMismatches.isEmpty && comparison?.isSetIdentical == true }
    }

    public static func check(packages: [CorpusPackage],
                             screenCells: [RunStore.CellKey: RunStore.LoadedCell],
                             runCells: [RunStore.CellKey: RunStore.LoadedCell]) -> Result {
        func key(_ p: CorpusPackage) -> RunStore.CellKey {
            RunStore.CellKey(toolchain: Screen.toolchain.name, mode: .strictCompleteV5, packageId: p.id)
        }
        let keys = Set(packages.map(key))
        let left = screenCells.filter { keys.contains($0.key) }
        let right = runCells.filter { keys.contains($0.key) }

        var mismatches: [InputMismatch] = []
        for p in packages.sorted(by: { $0.id < $1.id }) {
            // A cell on one side only is the comparison's to report (only-in-left/right), not an input mismatch.
            guard let l = left[key(p)]?.record, let r = right[key(p)]?.record else { continue }
            func require(_ field: String, _ a: String?, _ b: String?, nilAllowed: Bool = false) {
                guard a != b || (a == nil && !nilAllowed) else { return }
                mismatches.append(InputMismatch(packageId: p.id, field: field, screen: a ?? "nil", run: b ?? "nil"))
            }
            if l.sha != p.sha || r.sha != p.sha {
                mismatches.append(InputMismatch(packageId: p.id, field: "sha (manifest \(p.sha))", screen: l.sha, run: r.sha))
            }
            require("resolved_file_sha256", l.resolvedFileSHA256, r.resolvedFileSHA256)
            require("image_id", l.imageID, r.imageID)
            require("xcode_build", l.xcodeBuild, r.xcodeBuild, nilAllowed: true)
        }
        return Result(inputMismatches: mismatches,
                      comparison: mismatches.isEmpty ? RunComparison.compare(left, right) : nil,
                      ignoredScreenCells: screenCells.count - left.count, ignoredRunCells: runCells.count - right.count)
    }
}
```

(`require` records a mismatch when the values differ, or when both are nil and nil is not allowed. A resolved-file hash or image ID that was never recorded cannot show the inputs were the same.)

- [ ] **Step 4: Run the tests and confirm they pass**

Run: `swift test --package-path tools --filter ScreenReproductionTests 2>&1 | tail -5`
Expected: all 5 pass.

- [ ] **Step 5: Commit**

```bash
git add tools/Sources/CensusRunner/ScreenReproduction.swift tools/Tests/CensusRunnerTests/ScreenReproductionTests.swift
git commit -m "Screen reproduction check: S-emit macOS cells must equal their screen cells

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: `census screen reproduce`, plus two refactors it needs

**Files:**
- Modify: `tools/Sources/census/Census.swift` (extract `printComparison` from `Compare.run`)
- Modify: `tools/Sources/census/Screen.swift` (extract `passOneCells`, use it in `Collect`, add `Reproduce`, register it)

**Interfaces:**
- Consumes: `ScreenReproduction.check` (Task 5); `ScreenPaths`, `ScreenOptions`, `Paths(corpus:)`, `Screen.batchCount`.
- Produces: `func printComparison(_ report: RunComparison.Report, left: String, right: String)` (file scope, `census` target); `private func passOneCells(_ sp: ScreenPaths) throws -> [RunStore.CellKey: RunStore.LoadedCell]` in `Screen.swift`; the CLI `census screen reproduce <screen-id> <run-directory> [--manifest m]`, which exits 0 if the screen reproduces and 1 otherwise.

- [ ] **Step 1: Extract `printComparison`**

In `tools/Sources/census/Census.swift`, replace the body of `Compare.run()` and add the free function after the `Compare` struct:

```swift
    func run() async throws {
        let l = try RunStore(root: URL(fileURLWithPath: left)).loadCells()
        let r = try RunStore(root: URL(fileURLWithPath: right)).loadCells()
        let report = RunComparison.compare(l, r)
        printComparison(report, left: left, right: right)
        if !report.isSetIdentical { throw ExitCode.failure }
    }
}

/// An A7 report as `census compare` prints it; shared with `census screen reproduce`.
func printComparison(_ report: RunComparison.Report, left: String, right: String) {
    print("cells compared: \(report.cellsCompared); set-identical: \(report.identical); "
        + "no-diagnostic outcomes (equal): \(report.noDiagnosticCells)")
    for k in report.onlyInLeft { print("only in \(left): \(k)") }
    for k in report.onlyInRight { print("only in \(right): \(k)") }
    for m in report.outcomeMismatches { print("OUTCOME DIFFERS \(m.key): \(m.left.rawValue) vs \(m.right.rawValue)") }
    for d in report.differing {
        print("MULTISET DIFFERS \(d.key): -\(d.difference.onlyInLeft.count) +\(d.difference.onlyInRight.count)")
        for k in d.difference.onlyInLeft.prefix(5) { print("  only left : \(k.id) \(k.path):\(k.line):\(k.col) \(k.severity.rawValue)") }
        for k in d.difference.onlyInRight.prefix(5) { print("  only right: \(k.id) \(k.path):\(k.line):\(k.col) \(k.severity.rawValue)") }
    }
    print(report.isSetIdentical ? "SET-IDENTICAL" : "NOT SET-IDENTICAL")
}
```

(The closing `}` at the top of this block closes `struct Compare`. Remove the old closing brace so there is exactly one.)

- [ ] **Step 2: Check the `compare` refactor changed nothing**

```bash
swift build --package-path tools
tools/.build/debug/census compare runs/2026-10-04 runs/2026-10-04-rerun > work/m1-exit/compare-after.txt; echo "exit $?"
diff work/m1-exit/compare-baseline.txt work/m1-exit/compare-after.txt && echo SAME
```

Expected: `exit 0`, `SAME`.

- [ ] **Step 3: Extract `passOneCells` and use it in `Collect`**

In `tools/Sources/census/Screen.swift`, add this below the existing `pool(_:verify:)` function:

```swift
/// Every pass-1 batch's cells, merged. A key in two batches is an error, never a silent overwrite.
private func passOneCells(_ sp: ScreenPaths) throws -> [RunStore.CellKey: RunStore.LoadedCell] {
    var cells: [RunStore.CellKey: RunStore.LoadedCell] = [:]
    for n in stride(from: 1, through: Screen.batchCount(try sp.loadCandidates().packages.count), by: 1) {
        for (k, cell) in try RunStore(root: sp.corpusPaths.runDirectory(sp.runId(batch: n))).loadCells() {
            guard cells.updateValue(cell, forKey: k) == nil else { throw ValidationError("cell \(k) appears in more than one batch run") }
        }
    }
    return cells
}
```

In `Collect.run()`, replace this block:

```swift
            var cells: [RunStore.CellKey: RunStore.LoadedCell] = [:]
            for n in stride(from: 1, through: Screen.batchCount(candidates.count), by: 1) {
                for (k, cell) in try RunStore(root: paths.runDirectory(sp.runId(batch: n))).loadCells() {
                    guard cells.updateValue(cell, forKey: k) == nil else { throw ValidationError("cell \(k) appears in more than one batch run") }
                }
            }
```

with:

```swift
            let cells = try passOneCells(sp)
```

- [ ] **Step 4: Check the `Collect` refactor changed nothing**

```bash
swift build --package-path tools
tools/.build/debug/census screen collect screen-2026-10-10 --with-verify | tail -3
git status --porcelain screens/
```

Expected: the same A7 line as ADR 0007 Results ("94 cells compared, 94 set-identical"), and `git status --porcelain screens/` prints nothing. If anything in `screens/` changed, the refactor altered behaviour: `git checkout -- screens/` and fix the refactor.

- [ ] **Step 5: Add `Reproduce`**

In `Screen.swift`, register the subcommand:

```swift
        subcommands: [Batch.self, Batches.self, Collect.self, Status.self, Reproduce.self])
```

Add it inside `extension ScreenCommand`:

```swift
    struct Reproduce: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Do a macOS run's S-emit strict-complete-v5 cells reproduce the screen's pass-1 cells (A7)?",
            discussion: "Spec 2026-10-11 §3.2. Exit 1 if not, including when any entry's SHA, resolved file, guest image "
                + "or Xcode build differs between the two sides (then nothing is compared).")

        @OptionGroup var screen: ScreenOptions
        @Argument(help: "macOS run directory, e.g. runs/2026-10-11-macos.") var runDirectory: String
        @Option(name: .long, help: "Corpus manifest holding the S-emit entries.") var manifest = "corpus/packages.yaml"

        func run() async throws {
            let sp = screen.paths
            let packages = try Paths(corpus: URL(fileURLWithPath: manifest)).loadManifest().packages
                .filter { $0.stratum == .emit && $0.screenId == sp.id }
            guard !packages.isEmpty else { throw ValidationError("no S-emit entries in \(manifest) carry screen_id \(sp.id)") }
            let result = ScreenReproduction.check(
                packages: packages, screenCells: try passOneCells(sp),
                runCells: try RunStore(root: URL(fileURLWithPath: runDirectory)).loadCells())
            print("S-emit entries: \(packages.count); ignored cells: screen \(result.ignoredScreenCells), "
                + "run \(result.ignoredRunCells)")
            for m in result.inputMismatches { print("INPUT DIFFERS \(m)") }
            if let comparison = result.comparison {
                printComparison(comparison, left: "screen \(sp.id)", right: runDirectory)
            } else {
                print("NOT COMPARED: the two sides were built from different inputs")
            }
            if !result.isReproduced { throw ExitCode.failure }
        }
    }
```

- [ ] **Step 6: Smoke test on real data: the verify pass must reproduce pass 1**

The verify run `runs/screen-2026-10-10-macos-verify` re-built all 47 emitters in both modes, and ADR 0007 Results found them set-identical. So the 30 selected entries' v5 cells must reproduce:

```bash
swift build --package-path tools
tools/.build/debug/census screen reproduce screen-2026-10-10 runs/screen-2026-10-10-macos-verify; echo "exit $?"
```

Expected: `S-emit entries: 30; ignored cells: screen <n>, run 64` (the run's 94 cells minus 30), `cells compared: 30`, `SET-IDENTICAL`, `exit 0`.

Then check the failure path against a run that has none of the cells:

```bash
tools/.build/debug/census screen reproduce screen-2026-10-10 runs/2026-10-10-macos > work/m1-exit/reproduce-neg.txt; echo "exit $?"
grep -c '^only in screen' work/m1-exit/reproduce-neg.txt; tail -1 work/m1-exit/reproduce-neg.txt
```

Expected: `exit 1`, `30` (that run predates `S-emit`, so it has none of the 30 cells), `NOT SET-IDENTICAL`.

- [ ] **Step 7: Full test suite**

Run: `swift test --package-path tools 2>&1 | tail -3`
Expected: everything passes. The count is the Task 1 baseline + 22.

- [ ] **Step 8: Commit**

```bash
git add tools/Sources/census/Census.swift tools/Sources/census/Screen.swift
git commit -m "census screen reproduce; share the A7 printer and the pass-1 loader

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7: Preflight script

**Files:**
- Create: `scripts/matrix-preflight.sh` (mode 755)

**Interfaces:**
- Consumes: the pinned values in Global Constraints; `tools/vm/census-macos.yaml`.
- Produces: `scripts/matrix-preflight.sh linux|macos <freeze-commit>`, which exits 0 and prints `preflight OK (…)`, or exits 1 and prints `preflight FAILED: <first failure>` to stderr.

- [ ] **Step 1: Write the script**

```bash
#!/bin/bash
# scripts/matrix-preflight.sh: refuse to start an M1-exit run whose inputs are not ADR 0008's (spec 2026-10-11 §3.3).
#
#   scripts/matrix-preflight.sh linux <freeze-commit>   before each Linux run (Docker Desktop running)
#   scripts/matrix-preflight.sh macos <freeze-commit>   before each macOS run (Docker Desktop quit)
#
# <freeze-commit> is the tools commit all four runs use. Exits 1 naming the first failure. PREFLIGHT_ID_64 overrides the
# 6.4 pin only so the failure path can be tested; never set it for a run. bash 3.2: no associative arrays.
set -euo pipefail
cd "$(dirname "$0")/.."

usage="usage: matrix-preflight.sh linux|macos <freeze-commit>"
PLATFORM="${1:?$usage}"
FREEZE="${2:?$usage}"

# ADR 0008: the images the 2026-10-04 pair recorded. Nothing is pulled until the last M1-exit run is committed.
IMAGES=(
  "swift:6.1=sha256:6e43114610e161e38ad41636ebcafd6940dc67dfab355eace3a0ca100b2263db"
  "swift:6.2=sha256:eccc7a97f9b9881d9659e2e788081fd7675f86d39793b51200bfb178398b3784"
  "swift:6.3=sha256:cd45c27b3abc42310c33cfaf3008b18156cbdc9187834c9617e8f43a26d2675c"
  "swift:6.4=${PREFLIGHT_ID_64:-sha256:4601bf61dab9485a3e93087770b72d268737e945a5b000e2286b6cc48bb048b6}"
  "swiftlang/swift:nightly-main-jammy=sha256:191f78f3b9570ccdd382437b07ea0e8f98750206b96c71bad4f9515ec3aed4d2"
)
GUEST_DIGEST="sha256:2f016638293c3e641b8b25391a76fbc16563b3711915a5551cf8aa0f5598a5c1"
MIN_FREE_GB=40

fail() { echo "preflight FAILED: $*" >&2; exit 1; }

git rev-parse --verify --quiet "$FREEZE^{commit}" >/dev/null || fail "$FREEZE is not a commit"
[[ -z "$(git status --porcelain -- tools corpus)" ]] || fail "tools/ or corpus/ has uncommitted changes"
[[ -z "$(git diff --name-only "$FREEZE" HEAD -- tools corpus)" ]] || fail "tools/ or corpus/ changed since $FREEZE"

free_kb="$(df -k . | tail -1 | tr -s ' ' | cut -d' ' -f4)"
(( free_kb >= MIN_FREE_GB * 1024 * 1024 )) || fail "only $((free_kb / 1024 / 1024)) GB free; need $MIN_FREE_GB"

case "$PLATFORM" in
  linux)
    docker info >/dev/null 2>&1 || fail "Docker is not running"
    for pair in "${IMAGES[@]}"; do
      image="${pair%%=*}"
      want="${pair#*=}"
      # One image per call: on this Docker, `docker image inspect a b` reports bare `swift:` tags as missing.
      got="$(docker image inspect --format '{{.Id}}' "$image" 2>/dev/null)" || fail "$image is not present (do not pull: ADR 0008)"
      [[ "$got" == "$want" ]] || fail "$image is $got; ADR 0008 pins $want"
    done
    ;;
  macos)
    if docker info >/dev/null 2>&1; then fail "Docker Desktop is running; quit it first (it and the guest do not fit in 16 GiB)"; fi
    grep -q "digest: \"$GUEST_DIGEST\"" tools/vm/census-macos.yaml || fail "tools/vm/census-macos.yaml does not pin $GUEST_DIGEST"
    if limactl list -q 2>/dev/null | grep -q '^census-run-'; then fail "a census-run-* Lima clone is left over; limactl delete -f it"; fi
    ;;
  *) fail "platform must be linux or macos, not $PLATFORM" ;;
esac
echo "preflight OK ($PLATFORM, freeze $FREEZE)"
```

```bash
chmod 755 scripts/matrix-preflight.sh
```

- [ ] **Step 2: Lint**

Run: `docker run --rm -v "$PWD:/mnt" -w /mnt koalaman/shellcheck:stable scripts/matrix-preflight.sh; echo "exit $?"`
Expected: no findings, `exit 0`. Fix any findings, but leave the pinned values alone.

- [ ] **Step 3: Exercise the pass and failure paths** (Docker running)

```bash
scripts/matrix-preflight.sh linux HEAD; echo "exit $?"
PREFLIGHT_ID_64=sha256:bogus scripts/matrix-preflight.sh linux HEAD; echo "exit $?"
scripts/matrix-preflight.sh macos HEAD; echo "exit $?"
scripts/matrix-preflight.sh linux HEAD~1; echo "exit $?"
```

Expected, in order:
1. `preflight OK (linux, freeze HEAD)`, `exit 0`
2. `preflight FAILED: swift:6.4 is sha256:4601…; ADR 0008 pins sha256:bogus`, `exit 1`
3. `preflight FAILED: Docker Desktop is running; …`, `exit 1`
4. `preflight FAILED: tools/ or corpus/ changed since HEAD~1`, `exit 1` (Task 6 changed tools/)

- [ ] **Step 4: Commit**

```bash
git add scripts/matrix-preflight.sh
git commit -m "scripts/matrix-preflight.sh: refuse runs whose inputs are not ADR 0008's

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 8: Freeze the tools commit

**Files:** none tracked. Writes `work/m1-exit/FREEZE` and `work/m1-exit/DATE`.

**Interfaces:**
- Produces: `FREEZE` (the 40-char commit every run uses), `D` (the run-id date), and the release binary `tools/.build/release/census`.

- [ ] **Step 1: Freeze, build release, push**

```bash
git status --porcelain            # must print nothing
git rev-parse HEAD > work/m1-exit/FREEZE
date -u +%Y-%m-%d > work/m1-exit/DATE
swift build -c release --package-path tools 2>&1 | tail -1
git push -q
echo "FREEZE=$(cat work/m1-exit/FREEZE) D=$(cat work/m1-exit/DATE)"
```

Expected: an empty status, a successful build, and both values printed. From here until Task 12, **no commit may touch `tools/` or `corpus/`**. The preflight enforces this.

- [ ] **Step 2: Check that no run id is taken**

Run: `D=$(cat work/m1-exit/DATE); ls -d runs/$D runs/$D-rerun runs/$D-macos runs/$D-macos-rerun 2>&1`
Expected: four `No such file or directory` lines. If any exists, stop and ask the owner. Never reuse a run id.

---

### Task 9: Linux run, first pass (`<D>`)

**Files:**
- Create: `runs/<D>/` (written by `census run`)

- [ ] **Step 1: Preflight**

Run: `scripts/matrix-preflight.sh linux "$(cat work/m1-exit/FREEZE)"`
Expected: `preflight OK (linux, …)`. On failure, stop. Do not work around it.

- [ ] **Step 2: Launch in the background**

```bash
D=$(cat work/m1-exit/DATE)
caffeinate -i tools/.build/release/census run --run-id "$D" --platform linux \
  --jobs 1 --cpus 8 --memory-gb 7 --timeout-minutes 60 > work/m1-exit/linux-a.log 2>&1
```

Use the Bash tool with `run_in_background: true`. The `2026-10-04` precedent was about 1 h of summed build time for 185 cells, so expect 2–3 h for 335. **If the command dies or the session ends, re-issue exactly the same command.** It skips cells that already have `cell.json`. Never pass `--force`.

- [ ] **Step 3: Check completeness and outcomes**

```bash
D=$(cat work/m1-exit/DATE)
find runs/$D -name cell.json | wc -l
grep -rh --include=cell.json '"outcome"' runs/$D | sort | uniq -c
grep -h '"tools_git_dirty"\|"tools_git_commit"' runs/$D/run.json
grep -rh --include=cell.json '"image_id"' runs/$D | sort | uniq -c
```

Expected: `335`; an outcome table; `"tools_git_dirty" : false` and the FREEZE commit; exactly the five pinned image IDs.

- [ ] **Step 4: The one infra retry (only if `infra_error` > 0)**

```bash
D=$(cat work/m1-exit/DATE)
grep -rl --include=cell.json '"outcome" : "infra_error"' runs/$D | tee work/m1-exit/linux-a-infra.txt
while read -r f; do rm -r "$(dirname "$f")"; done < work/m1-exit/linux-a-infra.txt
```

Then repeat Steps 1–3 with the log `work/m1-exit/linux-a-retry.log`. Do this **once**. Cells still `infra_error` stay, and Task 13 records them.

- [ ] **Step 5: Commit the run**

```bash
D=$(cat work/m1-exit/DATE)
git add runs/$D
git commit -m "Run $D: Linux, full corpus, 5 toolchains (ADR 0008 first pass)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
git push -q
```

---

### Task 10: Linux run, second pass (`<D>-rerun`)

**Files:**
- Create: `runs/<D>-rerun/`

- [ ] **Step 1: Preflight**

Run: `scripts/matrix-preflight.sh linux "$(cat work/m1-exit/FREEZE)"`
Expected: `preflight OK`. HEAD has moved by one runs-only commit, which the preflight allows (Review Focus 1).

- [ ] **Step 2: Launch in the background**

```bash
D=$(cat work/m1-exit/DATE)
caffeinate -i tools/.build/release/census run --run-id "$D-rerun" --platform linux \
  --jobs 1 --cpus 8 --memory-gb 7 --timeout-minutes 60 > work/m1-exit/linux-b.log 2>&1
```

`run_in_background: true`. Resume by re-issuing the same command, and never use `--force`.

- [ ] **Step 3: Check completeness and outcomes**

The checks are the same as Task 9 Step 3, with `runs/$D-rerun`. Expected: `335`, `"tools_git_dirty" : false`, and the five pinned image IDs. `tools_git_commit` is the Task 9 commit, not FREEZE. Task 12 checks it.

- [ ] **Step 4: The one infra retry (only if `infra_error` > 0)**

This is the same procedure as Task 9 Step 4, with `runs/$D-rerun`, `work/m1-exit/linux-b-infra.txt` and the log `linux-b-retry.log`. Do it once.

- [ ] **Step 5: Commit the run**

```bash
D=$(cat work/m1-exit/DATE)
git add runs/$D-rerun
git commit -m "Run $D-rerun: Linux re-run on identical inputs (A7)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
git push -q
```

---

### Task 11: macOS pair (`<D>-macos`, `<D>-macos-rerun`)

**Files:**
- Create: `runs/<D>-macos/`, `runs/<D>-macos-rerun/`

- [ ] **Step 1: Quit Docker Desktop and confirm it is down**

```bash
osascript -e 'quit app "Docker Desktop"'
```

Then poll until `docker info >/dev/null 2>&1` fails. Use the Monitor tool with an until-loop, not a foreground `sleep`.

- [ ] **Step 2: Preflight**

Run: `scripts/matrix-preflight.sh macos "$(cat work/m1-exit/FREEZE)"`
Expected: `preflight OK (macos, …)`.

- [ ] **Step 3: First pass, in the background**

```bash
D=$(cat work/m1-exit/DATE)
caffeinate -i tools/.build/release/census run --run-id "$D-macos" --platform macos \
  --timeout-minutes 60 > work/m1-exit/mac-a.log 2>&1
```

`run_in_background: true`. Each run clones the golden guest and deletes the clone afterwards. If it dies, run `limactl list` and `limactl delete -f` any `census-run-*` clone, then re-issue the same command.

- [ ] **Step 4: Check completeness, then the one infra retry**

```bash
D=$(cat work/m1-exit/DATE)
find runs/$D-macos -name cell.json | wc -l
grep -rh --include=cell.json '"outcome"' runs/$D-macos | sort | uniq -c
grep -h '"tools_git_dirty"' runs/$D-macos/run.json
grep -rh --include=cell.json '"image_id"' runs/$D-macos | sort | uniq -c
```

Expected: `69`, `"tools_git_dirty" : false`, and one image ID, `ipsw-sha256:2f016638…`. If there is any `infra_error`, delete those cell directories once (the same loop as Task 9 Step 4, writing to `work/m1-exit/mac-a-infra.txt`), then repeat Steps 2–4.

- [ ] **Step 5: Commit the first pass**

```bash
D=$(cat work/m1-exit/DATE)
git add runs/$D-macos
git commit -m "Run $D-macos: macOS, full corpus, Xcode 27.0 (ADR 0008 first pass)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
git push -q
```

- [ ] **Step 6: Second pass**

Run the preflight (Step 2), then:

```bash
D=$(cat work/m1-exit/DATE)
caffeinate -i tools/.build/release/census run --run-id "$D-macos-rerun" --platform macos \
  --timeout-minutes 60 > work/m1-exit/mac-b.log 2>&1
```

Then run the Step 4 checks against `runs/$D-macos-rerun` (`mac-b-infra.txt` for any retry).

- [ ] **Step 7: Commit and push the second pass**

```bash
D=$(cat work/m1-exit/DATE)
git add runs/$D-macos-rerun
git commit -m "Run $D-macos-rerun: macOS re-run in a fresh guest clone (A7)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
git push -q
```

- [ ] **Step 8: Restart Docker Desktop**

Run: `open -a "Docker Desktop"`. Then confirm `limactl list` shows no `census-run-*` clone.

---

### Task 12: Evaluate

**Files:**
- Create: `runs/<D>/g2.json`; check outputs under `work/m1-exit/` (untracked, quoted into ADR 0008 in Task 13)

Run every step even if an earlier one fails (spec §5). Record each exit status.

- [ ] **Step 1: One tools commit, one manifest**

```bash
D=$(cat work/m1-exit/DATE); FREEZE=$(cat work/m1-exit/FREEZE)
for r in $D $D-rerun $D-macos $D-macos-rerun; do
  c=$(sed -n 's/.*"tools_git_commit" : "\(.*\)".*/\1/p' runs/$r/run.json)
  dirty=$(sed -n 's/.*"tools_git_dirty" : \([a-z]*\).*/\1/p' runs/$r/run.json)
  manifest=$(sed -n 's/.*"corpus_manifest_sha256" : "\(.*\)".*/\1/p' runs/$r/run.json)
  git diff --quiet "$FREEZE" "$c" -- tools corpus && same=yes || same=NO
  echo "$r commit=$c tools/corpus-unchanged=$same dirty=$dirty manifest=$manifest"
done | tee work/m1-exit/check-0-freeze.txt
```

Expected: four lines, each with `tools/corpus-unchanged=yes`, `dirty=false`, and the same `manifest=` hash.

- [ ] **Step 2: A7, Linux**

Run: `D=$(cat work/m1-exit/DATE); tools/.build/release/census compare runs/$D runs/$D-rerun | tee work/m1-exit/check-1-a7-linux.txt; echo "exit ${PIPESTATUS[0]}"`
Expected: `SET-IDENTICAL`, exit 0.

- [ ] **Step 3: A7, macOS**

Run: `D=$(cat work/m1-exit/DATE); tools/.build/release/census compare runs/$D-macos runs/$D-macos-rerun | tee work/m1-exit/check-2-a7-macos.txt; echo "exit ${PIPESTATUS[0]}"`
Expected: `SET-IDENTICAL`, exit 0.

- [ ] **Step 4: Screen reproduction**

Run: `D=$(cat work/m1-exit/DATE); tools/.build/release/census screen reproduce screen-2026-10-10 runs/$D-macos | tee work/m1-exit/check-3-reproduce.txt; echo "exit ${PIPESTATUS[0]}"`
Expected: `cells compared: 30`, `SET-IDENTICAL`, exit 0.

- [ ] **Step 5: G2**

Run: `D=$(cat work/m1-exit/DATE); tools/.build/release/census gate g2 runs/$D --json runs/$D/g2.json | tee work/m1-exit/check-4-g2.txt; echo "exit ${PIPESTATUS[0]}"`
Expected: a verdict line. Exit 0 means pass, 1 fail, 2 not evaluable. Any of the three is a result. Do not re-run anything to change it.

- [ ] **Step 6: Investigate any failed check before writing it up**

If Steps 1–4 failed: write down for each differing cell what differs, the way `runs/README.md` did for the 3 GB OOM case (for example by reading both `build.log.gz` files). **Do not re-run** to get green (ADR 0008). If an instrument bug is the cause, stop and report it to the owner. The fix and the re-run of both passes are a new decision.

- [ ] **Step 7: Commit the G2 report**

```bash
D=$(cat work/m1-exit/DATE)
git add runs/$D/g2.json
git commit -m "G2 report for run $D (ADR 0008)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 13: Write-up

**Files:**
- Modify: `docs/decisions/0008-m1-exit-runs-and-g2.md` (replace only the `## Results` section's "Not yet run.")
- Modify: `runs/README.md`
- Modify: `ROADMAP.md` (the M1 section, lines ~474–491)
- Modify: `/Users/aj/.claude/projects/-Users-aj-iOS-SwiftCensus/memory/project_s_emit_screen_in_progress.md` and `MEMORY.md` (outside the repo)

- [ ] **Step 1: ADR 0008 Results**

Replace `Not yet run.` with the following, filled from `work/m1-exit/*` and the committed runs. Give numbers only, and state each check's output verbatim where it is one line:

```markdown
Pre-registration committed at `<ADR0008_COMMIT>`. Tools frozen at `<FREEZE>`. Runs `<D>`, `<D>-rerun` (Linux, aarch64), `<D>-macos`, `<D>-macos-rerun` (Xcode 27.0 <build>, guest <os build>), started <times>Z.

### Checks

| Check | Command | Result |
|---|---|---|
| One tools commit | `git diff <FREEZE> <run commit> -- tools corpus` ×4 | <all empty / which not> |
| A7 Linux (M1 exit) | `census compare runs/<D> runs/<D>-rerun` | <SET-IDENTICAL over N cells / details> |
| A7 macOS (M1 exit) | `census compare runs/<D>-macos runs/<D>-macos-rerun` | <…> |
| Screen reproduction | `census screen reproduce screen-2026-10-10 runs/<D>-macos` | <…> |
| G2 | `census gate g2 runs/<D>` | <PASS / FAIL / NOT EVALUABLE>, `runs/<D>/g2.json` |

### Outcomes per run

<the outcome table for each of the four runs, from the `uniq -c` output; infra retries and what they changed>

### G2

| column | emits / 30 | % | any outcome (non-gating) | head | middle | tail |
|---|---|---|---|---|---|---|
<one row per column from check-4-g2.txt, 6.4 first and marked gating>

Not emitting on Linux 6.4: <each package, tertile, outcome, primary non-note count>.

### Not verified

<what these runs cannot tell, e.g. why particular S-emit entries fail on Linux; anything investigated but not closed>
```

If a check failed, the Results section says so in its first sentence, and adds a sentence saying M1 is **not** exited.

- [ ] **Step 2: `runs/README.md`**

Add four rows to the run table:

```markdown
| `<D>` | M1-exit Linux run (ADR 0008): full corpus, 5 toolchains, 335 cells. G2 is scored on this run. |
| `<D>-rerun` | Identical inputs, re-run for the A7 check. |
| `<D>-macos` | M1-exit macOS run (ADR 0008): full corpus, Xcode 27.0, 69 cells. |
| `<D>-macos-rerun` | Re-run of the above in a fresh guest clone. |
```

Add the two `census compare` result lines under the existing ones. In "What these runs are not", replace the first bullet ("Not the M1 exit. …") with one line stating the M1-exit status and G2 verdict, pointing to ADR 0008 Results.

- [ ] **Step 3: ROADMAP M1**

After the `**Exit (per A7):** …` paragraph in §3 M1, add one line:

```markdown
**Status (<today>):** <met | not met> — see ADR 0008 Results. G2 (ADR 0007 D8): <PASS n/30 | FAIL n/30 | not evaluable>.
```

Do not touch M2.

- [ ] **Step 4: Commit and push**

```bash
git add docs/decisions/0008-m1-exit-runs-and-g2.md runs/README.md ROADMAP.md
git commit -m "ADR 0008 results: M1-exit runs and G2

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
git push -q
```

- [ ] **Step 5: Update the memory note**

Rewrite `project_s_emit_screen_in_progress.md` (keep its frontmatter `name`; update `description`). It should say: the S-emit matrix runs are done on branch `m1/s-emit-matrix`, the run ids, the M1-exit status, the G2 verdict, and the next step (M2 if both passed; otherwise the owner's investigation decision). Update its line in `MEMORY.md` to match. Keep the link to `[[adr-0005-open-owner-decision]]`.
```
