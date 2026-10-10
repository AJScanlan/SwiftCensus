# macOS Screen for `S-emit` — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the instrument that selects the `S-emit` stratum by measurement: draw ~300 candidates, build each on the macOS guest under `strict-complete-v5` and `minimal-v5`, count what strict checking adds, and sample 30 by tertile. All of it runs from an unattended driver that can be resumed at any point.

**Architecture:** The pure logic goes in `CensusRunner` (`Draw.swift`, `Screen.swift`) and is tested with swift-testing: the seeded draw, the differential count, status classification, the denominator, the CSV export, selection and copying of `.resolved` files. The `census` executable gets thin commands (`select screen`, `screen batch|batches|collect|status`, `select emit --from-screen`) that do I/O and call the pure layer. `scripts/screen-drive.sh` orders the long phases. The cells on disk are the source of truth, and the script's marker files are only an optimisation.

**Tech Stack:** Swift 6 language mode (`tools/`, swift-tools-version 6.0), swift-testing, swift-argument-parser 1.8.2, Yams 6.2.2, Lima (`limactl`), Docker Desktop, bash.

**Spec:** `docs/superpowers/specs/2026-10-10-macos-screen.md` (D1–D12 confirmed by the owner on 2026-10-10). Read it with this plan. Also read `CLAUDE.md`, ADRs 0001–0006, `runs/README.md` and `corpus/README.md`.

**Branch:** `m1/matrix-runner`. Do not create a new branch.

**Conventions for every task:**
- Run every command from the repository root `/Users/aj/iOS/SwiftCensus`.
- Build with `swift build --package-path tools`. Test with `swift test --package-path tools` (filter with `--filter <SuiteName>`).
- The CLI is `tools/.build/debug/census` after a debug build.
- Commit messages end with a blank line and then `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Code style follows the surrounding code: `///` doc comments that explain *why*, short and dense; `public` API in `CensusRunner`/`CensusCore`; snake_case `CodingKeys`; no force-unwraps in production code.

## Global Constraints

- Build mode `strict-complete-v5` = `-strict-concurrency=complete` + forced `-swift-version 5` (ADR 0002). `minimal-v5` is identical except `-strict-concurrency=minimal`.
- Frame: `SwiftPackageIndex/PackageList` @ `4dc1035a98457e87f4d2c5649a33cd43ee6b80e8`. Do not refresh it (D2).
- Draw seed `20261004`, continuing S-control's order; skip every id in `corpus/packages.yaml`, all strata and skipped entries included (D3).
- Candidate count: **300**, fixed, with no early stop (D4). One extension of +150 only if fewer than 45 stable emitters (D5).
- Toolchain: one, Xcode 27.0 (`Toolchain.macOSXcode`, name `xcode-27.0`), platform `macos-spm` (D7).
- Sample: 30, tertiles, seed `20261010`, via `Selection.sampleAcrossDistribution` (D11).
- Screen id `screen-2026-10-10`. Candidates live in `screens/<id>/`, and runs in `runs/<id>-macos-bN` and `runs/<id>-macos-verify`.
- Batches of **50**, one fresh guest clone per batch.
- `emitters.csv` header is exactly `package_url,data_race_errors,swift_version,as_of`; `swift_version` = `xcode-27.0-minimal-diff`.
- Never fetch from swiftpackageindex.com. Never bump a corpus SHA or a vendored `Package.resolved` as a drive-by. Never modify a committed `runs/` directory.
- No new package dependencies. New types are `Sendable` (G9). YAML output uses `sortKeys` (G9).
- Do not create `entries/` or `EntryVerify/`.
- ADR 0007 is committed **before** any screening build. After that, only its "Results" section may change.

## Deviations from the spec's literal text (for owner review before execution)

Each one is also recorded in ADR 0007 (Task 1).

- **V1: `census screen batch` replaces `census run --mode … minimal-v5` for the screen. `--mode` is not added to `census run`.** `modes(for:)` stays unchanged, as the spec requires, so a `--mode` *filter* on `census run` could never select `minimal-v5` for screen candidates. The batch command plans its own cells (complete first, then minimal only where needed) inside one guest clone per batch. That matches the spec's "each batch a separate run with its own fresh guest clone." `--mode` would have no use, so it is deleted rather than deferred.
- **V2: A `timeout` complete cell is `not_screenable` with reason `timeout`.** §5.4 does not list timeout. Like `build_failed`, it censors the measurement (bias 4).
- **V3: `provenance.json` and a new `failures.json` live at `screens/<id>/resolved/`.** That mirrors `corpus/resolved/provenance.json`, which the resolver already writes there.
- **V4: `ScreenResult.complete_outcome` is optional** (nil for `unresolvable`, which has no cell). An added `verify_screen_count` makes `unstable` auditable.
- **V5: `census screen collect --with-verify` exits non-zero** when the *stable* emitters' cells are not A7 set-identical across the two passes (same count, different multiset). The driver then STOPs. This is the "census compare on the verify run passes" acceptance check. Plain `census compare` cannot take several pass-1 run directories.
- **V6: `candidates.yaml` is kept in draw order, not sorted, and batches are positional slices of it.** An extension (`--extend`) appends and never reshuffles finished batches.
- **Fix, not a deviation:** the outcome classifier recognised a compile only when it saw `-strict-concurrency=complete`. Minimal cells would be misclassified (Task 2).

## Review Focus

These failure modes are implied by the spec but no requirement names them. Each one gets a test in the task listed.

1. **A `minimal-v5` cell is misread because the classifier only knows `=complete`.** The F7 frontend sample would be nil, and a minimal build failure that mentions "out-of-date" would become `resolve_failed`. Test in Task 2: `minimalModeCompileLineIsRecognised`.
2. **`select emit --from-screen` run after the pass-1 collect but before `--with-verify`.** It would sample emitters nobody checked for stability. It must refuse. Test in Task 10: `refusesEmittersThatWereNeverVerified`.
3. **A D5 extension reshuffles or re-draws earlier candidates.** That would invalidate finished batches and break the "one frame, one order" claim. The extension must continue after the last draw position. Tests in Task 5 (`extensionContinuesTheSameOrder`, `encodingKeepsDrawOrderAndIsByteStable`) and Task 7 (`batchesArePositionalSoAnExtensionOnlyAppends`).
4. **A candidate with no cell and no recorded resolve failure** (resolve never reached it, or a batch was skipped) is silently left out. The denominator would still look plausible. It must be an error. Tests in Task 7 (`aMissingCellIsAnErrorNeverASilentGap`, `aMissingOrDuplicatedCandidateFailsTheAssertion`).
5. **SIGKILL of the driver leaves its child `census screen batch` running.** A relaunch would race it for the guest name and the cells. The driver must reap orphans and stale `census-run-*` guests before it does anything else. Implemented in Task 11, demonstrated in Task 12.

---

### Task 1: ADR 0007 — pre-registration

**Files:**
- Create: `docs/decisions/0007-s-emit-by-macos-screen.md`

**Interfaces:**
- Consumes: nothing.
- Produces: the pre-registration that later tasks implement, word for word. The "Results" section is left empty for Task 14.

- [ ] **Step 1: Write the ADR**

````markdown
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

**Consequence: the screen measures the same quantity the census later reports.** On the screened toolchain and platform, an `S-emit` package's matrix count equals its screen count by construction. `S-emit` frequencies are therefore conditioned on "emits > 0". They are never an ecosystem estimate and are always reported separately from `S-control`.

### Pre-registration

| Item | Fixed value |
|---|---|
| Frame (D2) | `SwiftPackageIndex/PackageList` @ `4dc1035a98457e87f4d2c5649a33cd43ee6b80e8`, the commit `S-control` was drawn from |
| Order (D3) | Seed `20261004`. The same SplitMix64 Fisher–Yates over the sorted `owner/repo` ids as `S-control`. Every id in `corpus/packages.yaml` (all strata, skipped entries included) is a consumed position and is skipped |
| Count (D4) | **300** eligible candidates, fixed in advance. No stopping early |
| Extension (D5) | If fewer than **45** stable emitters remain after the 300: **one** extension of +150, continuing the same order after the last drawn position. Then proceed with whatever exists |
| Eligibility | GitHub repository; not archived or disabled; pushed within 365 days of the draw date; default-branch HEAD pinned to a 40-character SHA at draw time |
| Platform and toolchain (D7) | `macos-spm`, Xcode 27.0's Swift, in a fresh clone of the `census-macos` guest per batch of 50 |
| Modes | `strict-complete-v5` (`-strict-concurrency=complete`, `-swift-version 5` forced) and `minimal-v5` (identical but `-strict-concurrency=minimal`) |
| Count (D1) | `primaryKeys(cell)` = multiset of `(id ?? "text:"+text, path, line, col)` over records with attribution `primary` and severity ≠ `note`. `screen_count = |primaryKeys(complete) − primaryKeys(minimal)|` (multiset difference, left minus right) |
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
- `Mode.allCases` now includes `minimal-v5`, so future `run.json` files list it (G10). Committed runs are untouched.

## Results

_Empty until the screen has run. Then filled in factually: N drawn, the denominator table, the emit rate with its denominator, counts per tertile, instabilities, and whether D5 was applied. No interpretation beyond what the numbers support._
````

- [ ] **Step 2: Check it against the spec**

Run: `grep -c "" docs/decisions/0007-s-emit-by-macos-screen.md && grep -n "20261004\|20261010\|4dc1035a\|300\|45\|50%" docs/decisions/0007-s-emit-by-macos-screen.md`
Expected: every pre-registered value appears. Compare the table against spec §2 and §3 line by line.

- [ ] **Step 3: Commit**

```bash
git add docs/decisions/0007-s-emit-by-macos-screen.md
git commit -m "ADR 0007: S-emit by a macOS screen (pre-registration)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: `minimal-v5` mode and a mode-agnostic compile detector

**Files:**
- Modify: `tools/Sources/CensusCore/CellRecord.swift` (enum `Mode`)
- Modify: `tools/Sources/CensusRunner/Matrix.swift` (`BuildInvocation.swiftBuildArguments`)
- Modify: `tools/Sources/CensusRunner/OutcomeClassifier.swift` (`frontendInvocationSample`)
- Test: `tools/Tests/CensusRunnerTests/RunnerTests.swift` (suites `BuildInvocationTests`, `OutcomeClassifierTests`)

**Interfaces:**
- Consumes: nothing new.
- Produces: `Mode.minimalV5` (raw value `"minimal-v5"`). `BuildInvocation.swiftBuildArguments(mode: .minimalV5, …)` returns the v5 arguments with `-strict-concurrency=minimal`. `BuildInvocation.modes(for:)` is **unchanged**.

- [ ] **Step 1: Write the failing tests**

Add to `BuildInvocationTests` in `tools/Tests/CensusRunnerTests/RunnerTests.swift`:

```swift
    @Test func minimalModeIsMinimalAndStillForcesSwiftVersionFive() {
        let args = BuildInvocation.swiftBuildArguments(mode: .minimalV5)
        #expect(args.contains("-strict-concurrency=minimal"))
        #expect(!args.contains { $0.contains("complete") })
        let i = args.firstIndex(of: "-swift-version")
        #expect(i != nil && args[i! + 2] == "5")
        #expect(args.contains("-debug-diagnostic-names") && args.contains("-serialize-diagnostics"))
    }

    /// The differential (ADR 0007) is only meaningful if the two builds differ in nothing but the checking level.
    @Test func minimalDiffersFromV5OnlyInTheConcurrencyLevel() {
        let v5 = BuildInvocation.swiftBuildArguments(mode: .strictCompleteV5)
        let minimal = BuildInvocation.swiftBuildArguments(mode: .minimalV5)
        #expect(minimal == v5.map { $0 == "-strict-concurrency=complete" ? "-strict-concurrency=minimal" : $0 })
    }
```

Add to `OutcomeClassifierTests`:

```swift
    /// A minimal-v5 compile must count as "compile started": otherwise its F7 sample is nil and a failure
    /// mentioning "out-of-date" is misfiled as a resolve failure.
    @Test func minimalModeCompileLineIsRecognised() {
        let minimal = compileLine.replacingOccurrences(of: "=complete", with: "=minimal")
        #expect(OutcomeClassifier.frontendInvocationSample(in: "\(manifestLine)\n\(minimal)\n") == minimal)
        #expect(OutcomeClassifier.classify(exitCode: 1, timedOut: false, log: "\(minimal)\nerror: something is out-of-date") == .buildFailed)
    }
```

- [ ] **Step 2: Run the tests and watch them fail**

Run: `swift test --package-path tools --filter "BuildInvocationTests|OutcomeClassifierTests"`
Expected: compile error, `type 'Mode' has no member 'minimalV5'`.

- [ ] **Step 3: Implement**

In `tools/Sources/CensusCore/CellRecord.swift`, replace the `Mode` enum:

```swift
/// The measurement modes (ADR 0002). `v5` is the only frequency source.
public enum Mode: String, Codable, Sendable, CaseIterable {
    case strictCompleteV5 = "strict-complete-v5"
    /// SPI-comparable; retained for comparability and never a frequency source.
    case strictCompleteDeclared = "strict-complete-declared"
    /// ADR 0007's screen baseline: `-strict-concurrency=minimal` with `-swift-version 5` forced. Never a corpus mode
    /// and never a frequency source; it exists only to be subtracted from `strict-complete-v5`.
    case minimalV5 = "minimal-v5"
}
```

In `tools/Sources/CensusRunner/Matrix.swift`, in `swiftBuildArguments`, replace the opening of the argument list and the `-swift-version` condition:

```swift
        var args = [
            "swift", "build", "-v", "--force-resolved-versions", "--cache-path", cachePath,
            "-Xswiftc", "-strict-concurrency=\(mode == .minimalV5 ? "minimal" : "complete")",
        ]
        if mode != .strictCompleteDeclared {
            args += ["-Xswiftc", "-swift-version", "-Xswiftc", "5"]
        }
```

Add one sentence to that function's doc comment: `` `minimal-v5` differs from `strict-complete-v5` only in the checking level (ADR 0007). ``

In `tools/Sources/CensusRunner/OutcomeClassifier.swift`, in `frontendInvocationSample`, change the guard and its doc comment:

```swift
    /// The first compile command in the verbose build log that carries the census flags: the
    /// resolved frontend invocation (F7). The manifest compile precedes it and lacks the flags, so
    /// "first `-module-name` line" would record the wrong command. Keyed on `-strict-concurrency=`,
    /// not `=complete`, so `minimal-v5` cells (ADR 0007) are recognised too.
    public static func frontendInvocationSample(in log: String) -> String? {
        for line in log.split(separator: "\n", omittingEmptySubsequences: true) {
            guard line.contains(" -module-name "), line.contains("-strict-concurrency=") else { continue }
```

(The rest of the function is unchanged.)

- [ ] **Step 4: Run all tests**

Run: `swift test --package-path tools`
Expected: all pass, including the existing `v5ForcesSwiftVersionFive`, `declaredModeDoesNotForceSwiftVersion` and `frontendSampleSkipsTheManifestCompile`.

- [ ] **Step 5: Commit**

```bash
git add tools/Sources/CensusCore/CellRecord.swift tools/Sources/CensusRunner/Matrix.swift tools/Sources/CensusRunner/OutcomeClassifier.swift tools/Tests/CensusRunnerTests/RunnerTests.swift
git commit -m "Add minimal-v5 mode; recognise compiles at any strict-concurrency level" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: `Stratum.screen` and screen fields on `CorpusPackage`

**Files:**
- Modify: `tools/Sources/CensusCore/Corpus.swift`
- Test: `tools/Tests/CensusCoreTests/CoreTests.swift` (new suite `CorpusPackageCodingTests`)
- Test: `tools/Tests/CensusRunnerTests/RunnerTests.swift` (`onlyAnchorsGetTheDeclaredOverlay`)

**Interfaces:**
- Consumes: nothing new.
- Produces:
  - `Stratum.screen` (raw `"screen"`).
  - `CorpusPackage.screenId: String?` (`screen_id`) and `CorpusPackage.screenCountAtSelection: Int?` (`screen_count_at_selection`).
  - The initializer becomes `CorpusPackage(id:url:sha:stratum:platforms:selection:spiErrorCountAtSelection: = nil, screenId: = nil, screenCountAtSelection: = nil, skipReason: = nil)`.

- [ ] **Step 1: Write the failing tests**

Append to `tools/Tests/CensusCoreTests/CoreTests.swift`:

```swift
@Suite struct CorpusPackageCodingTests {
    let sha = String(repeating: "a", count: 40)

    @Test func entriesWrittenBeforeTheScreenStillDecode() throws {
        let json = #"{"id":"a/a","url":"https://github.com/a/a","sha":"\#(sha)","stratum":"S-control","platforms":["linux-spm"],"selection":"t","spi_error_count_at_selection":3}"#
        let p = try JSONDecoder().decode(CorpusPackage.self, from: Data(json.utf8))
        #expect(p.screenId == nil && p.screenCountAtSelection == nil && p.spiErrorCountAtSelection == 3)
    }

    /// The screen count has its own field: `spi_error_count_at_selection` is never reused for it (ADR 0007).
    @Test func screenFieldsRoundTripUnderSnakeCaseKeys() throws {
        let p = CorpusPackage(id: "a/a", url: "https://github.com/a/a", sha: sha, stratum: .emit, platforms: [.linuxSPM, .macosSPM],
                              selection: "t", screenId: "screen-2026-10-10", screenCountAtSelection: 7)
        let data = try JSONEncoder().encode(p)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"screen_id\"") && text.contains("\"screen_count_at_selection\""))
        #expect(!text.contains("spi_error_count_at_selection"))
        #expect(try JSONDecoder().decode(CorpusPackage.self, from: data) == p)
    }

    @Test func screenIsAStratum() {
        #expect(Stratum(rawValue: "screen") == .screen)
    }
}
```

In `tools/Tests/CensusRunnerTests/RunnerTests.swift`, in `onlyAnchorsGetTheDeclaredOverlay`, extend the loop so it pins `modes(for:)` for the new stratum:

```swift
        for s in [Stratum.emit, .control, .byproduct, .screen] { #expect(BuildInvocation.modes(for: s) == [.strictCompleteV5]) }
```

- [ ] **Step 2: Run the tests and watch them fail**

Run: `swift test --package-path tools --filter "CorpusPackageCodingTests|BuildInvocationTests"`
Expected: compile error, `extra arguments 'screenId', 'screenCountAtSelection'` / `type 'Stratum' has no member 'screen'`.

- [ ] **Step 3: Implement**

In `tools/Sources/CensusCore/Corpus.swift`:

```swift
public enum Stratum: String, Codable, Sendable, CaseIterable {
    case emit = "S-emit"
    case control = "S-control"
    case anchor = "S-anchor"
    case byproduct = "S-byproduct"
    /// ADR 0007: a screen candidate, kept in `screens/<id>/candidates.yaml`. Not a corpus stratum: labelling
    /// non-members `S-emit` would survive into `census validate` as a lie.
    case screen
}
```

In `CorpusPackage`, add after `spiErrorCountAtSelection`:

```swift
    /// ADR 0007: the screen this entry was selected from, and its `screen_count` then. Separate from the SPI field
    /// on purpose: the two signals measure different things and must never be mixed.
    public var screenId: String?
    public var screenCountAtSelection: Int?
```

Extend `CodingKeys`:

```swift
    enum CodingKeys: String, CodingKey {
        case id, url, sha, stratum, platforms, selection
        case spiErrorCountAtSelection = "spi_error_count_at_selection"
        case screenId = "screen_id"
        case screenCountAtSelection = "screen_count_at_selection"
        case skipReason = "skip_reason"
    }
```

Replace the initializer:

```swift
    public init(id: String, url: String, sha: String, stratum: Stratum, platforms: [Platform],
                selection: String, spiErrorCountAtSelection: Int? = nil, screenId: String? = nil,
                screenCountAtSelection: Int? = nil, skipReason: String? = nil) {
        self.id = id
        self.url = url
        self.sha = sha
        self.stratum = stratum
        self.platforms = platforms
        self.selection = selection
        self.spiErrorCountAtSelection = spiErrorCountAtSelection
        self.screenId = screenId
        self.screenCountAtSelection = screenCountAtSelection
        self.skipReason = skipReason
    }
```

Synthesized `Codable` uses `encodeIfPresent` for optionals, so the existing `packages.yaml` re-encodes byte-identically.

- [ ] **Step 4: Run all tests and validate the real corpus**

Run: `swift test --package-path tools && swift build --package-path tools && tools/.build/debug/census validate`
Expected: all tests pass. `validate` prints `36 packages; S-emit=0 S-control=30 S-anchor=4 S-byproduct=2 screen=0` and exits 0.

- [ ] **Step 5: Commit**

```bash
git add tools/Sources/CensusCore/Corpus.swift tools/Tests/CensusCoreTests/CoreTests.swift tools/Tests/CensusRunnerTests/RunnerTests.swift
git commit -m "Add Stratum.screen and screen provenance fields on CorpusPackage" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: Cell durations on `SuspendingClock`

**Files:**
- Create: `tools/Sources/CensusRunner/Elapsed.swift`
- Modify: `tools/Sources/CensusRunner/CellRunner.swift` (`run(package:toolchain:mode:imageID:)`)
- Modify: `tools/Sources/CensusRunner/MacCellRunner.swift` (`run(package:toolchain:mode:imageID:)`)
- Test: `tools/Tests/CensusRunnerTests/ElapsedTests.swift`

**Interfaces:**
- Produces: `Elapsed.seconds(_ d: Duration) -> Double`, rounded to 0.1 s.

- [ ] **Step 1: Write the failing test**

Create `tools/Tests/CensusRunnerTests/ElapsedTests.swift`:

```swift
import Testing

@testable import CensusRunner

@Suite struct ElapsedTests {
    @Test func roundsToATenthOfASecond() {
        #expect(Elapsed.seconds(.milliseconds(1234)) == 1.2)
        #expect(Elapsed.seconds(.milliseconds(1250)) == 1.3)
        #expect(Elapsed.seconds(.seconds(90)) == 90)
        #expect(Elapsed.seconds(.zero) == 0)
    }
}
```

- [ ] **Step 2: Run it and watch it fail**

Run: `swift test --package-path tools --filter ElapsedTests`
Expected: compile error, `cannot find 'Elapsed' in scope`.

- [ ] **Step 3: Implement**

Create `tools/Sources/CensusRunner/Elapsed.swift`:

```swift
/// Cell durations are measured on `SuspendingClock`, which does not advance while the host sleeps. `Date()`
/// differences do, and once recorded a 6,635 s cell when the machine slept mid-run. `caffeinate` prevents sleep;
/// this keeps a missed one from silently inflating a duration.
public enum Elapsed {
    public static func seconds(_ d: Duration) -> Double {
        let (s, atto) = d.components
        return ((Double(s) + Double(atto) / 1e18) * 10).rounded() / 10
    }
}
```

In **both** `CellRunner.run` and `MacCellRunner.run`, keep `let started = Date()` (it feeds `startedAt`) and add right after it:

```swift
        let clock = SuspendingClock()
        let start = clock.now
```

Replace the duration line in each:

```swift
        record.durationSeconds = Elapsed.seconds(start.duration(to: clock.now))
```

- [ ] **Step 4: Run all tests**

Run: `swift test --package-path tools`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add tools/Sources/CensusRunner/Elapsed.swift tools/Sources/CensusRunner/CellRunner.swift tools/Sources/CensusRunner/MacCellRunner.swift tools/Tests/CensusRunnerTests/ElapsedTests.swift
git commit -m "Measure cell durations on SuspendingClock" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: Shared seeded draw, deterministic YAML, and `census select screen`

**Files:**
- Create: `tools/Sources/CensusRunner/Draw.swift`
- Create: `tools/Sources/census/Screen.swift` (only `ScreenPaths` and `ScreenOptions` for now; Tasks 8 and 9 add to it)
- Modify: `tools/Sources/census/Select.swift` (whole file, shown below)
- Test: `tools/Tests/CensusRunnerTests/DrawTests.swift`

**Interfaces:**
- Consumes: `Stratum.screen` (Task 3), `Selection.seededShuffle`, `Selection.githubRepo`.
- Produces (in `CensusRunner`):
  - `enum Eligibility: Equatable, Sendable { case eligible(sha: String, branch: String); case rejected(String) }`
  - `struct DrawSpec: Sendable { seed: UInt64; count: Int; startPosition: Int; packageListSHA: String; date: String; stratum: Stratum; platforms: [Platform] }` with a public memberwise init in that order.
  - `struct DrawResult: Sendable { packages: [CorpusPackage]; rejected: [String: Int] }`
  - `Draw.repos(fromPackageList: [String]) -> [String: String]`
  - `Draw.draw(repos:spec:excluding:check:) async rethrows -> DrawResult`, where `check: (_ id: String, _ url: String) async throws -> Eligibility`
  - `Draw.MetadataCheck { case active(branch: String); case rejected(String) }` and `Draw.checkMetadata(_ tsv: String?, now: Date, activeDays: Int) -> MetadataCheck`
  - `Draw.position(inSelection: String) -> Int?`
  - `CorpusYAML.encode(_ manifest: CorpusManifest, header: String) throws -> String`
- Produces (in `census`): `ScreenPaths(root: String, id: String)` with `directory`, `candidates`, `resolved: URL` and `loadCandidates() throws -> CorpusManifest`; `ScreenOptions` (`@Argument id`, `--root`, default `screens`); `pinnedPackageListSHA`.

- [ ] **Step 1: Write the failing tests**

The golden order below was computed from the existing SplitMix64 shuffle. For ids `o/r0`…`o/r39` and seed `20261004`, the first ten are `o/r18, o/r12, o/r8, o/r28, o/r34, o/r33, o/r23, o/r3, o/r31, o/r20`.

Create `tools/Tests/CensusRunnerTests/DrawTests.swift`:

```swift
import CensusCore
import Foundation
import Testing

@testable import CensusRunner

@Suite struct DrawTests {
    let list = (0..<40).map { "https://github.com/o/r\($0).git" } + ["https://gitlab.com/x/y"]
    let sha = String(repeating: "b", count: 40)
    let golden = ["o/r18", "o/r12", "o/r8", "o/r28", "o/r34", "o/r33", "o/r23", "o/r3", "o/r31", "o/r20"]

    func spec(count: Int = 5, start: Int = 0) -> DrawSpec {
        DrawSpec(seed: 20261004, count: count, startPosition: start, packageListSHA: "4dc1035a98457e87f4d2c5649a33cd43ee6b80e8",
                 date: "2026-10-10", stratum: .screen, platforms: [.macosSPM])
    }

    func eligible(_ id: String, _ url: String) async -> Eligibility { .eligible(sha: String(repeating: "b", count: 40), branch: "main") }

    @Test func drawFollowsTheGoldenSeededOrder() async {
        let repos = Draw.repos(fromPackageList: list)
        #expect(repos.count == 40)  // the non-GitHub URL is dropped
        let r = await Draw.draw(repos: repos, spec: spec(), excluding: [], check: eligible)
        #expect(r.packages.map(\.id) == Array(golden.prefix(5)))
        #expect(r.packages.allSatisfy { $0.stratum == .screen && $0.platforms == [.macosSPM] && $0.sha == sha })
        #expect(r.packages[0].url == "https://github.com/o/r18")
        #expect(r.packages[0].selection
            == "seed=20261004 draw-position=0 PackageList@4dc1035a98457e87f4d2c5649a33cd43ee6b80e8 HEAD of main on 2026-10-10")
    }

    /// D3: corpus ids are consumed positions. They are skipped and the next ones taken.
    @Test func excludedIdsAreSkippedAndTheNextOnesTaken() async {
        let r = await Draw.draw(repos: Draw.repos(fromPackageList: list), spec: spec(), excluding: ["o/r18", "o/r8"], check: eligible)
        #expect(r.packages.map(\.id) == ["o/r12", "o/r28", "o/r34", "o/r33", "o/r23"])
        #expect(r.rejected == ["already in corpus or candidates": 2])
        #expect(Draw.position(inSelection: r.packages[0].selection) == 1)
    }

    @Test func ineligibleReposAreCountedByReasonAndReplacedByTheNext() async {
        let r = await Draw.draw(repos: Draw.repos(fromPackageList: list), spec: spec(count: 3), excluding: []) { id, _ in
            id == "o/r12" ? .rejected("archived or disabled") : .eligible(sha: String(repeating: "b", count: 40), branch: "main")
        }
        #expect(r.packages.map(\.id) == ["o/r18", "o/r8", "o/r28"])
        #expect(r.rejected == ["archived or disabled": 1])
    }

    /// D5: an extension continues after the last drawn position and never revisits earlier ones.
    @Test func extensionContinuesTheSameOrder() async {
        let repos = Draw.repos(fromPackageList: list)
        let first = await Draw.draw(repos: repos, spec: spec(count: 5), excluding: [], check: eligible)
        let last = first.packages.compactMap { Draw.position(inSelection: $0.selection) }.max()!
        let more = await Draw.draw(repos: repos, spec: spec(count: 3, start: last + 1),
                                   excluding: Set(first.packages.map(\.id)), check: eligible)
        #expect((first.packages + more.packages).map(\.id) == Array(golden.prefix(8)))
    }

    @Test func encodingKeepsDrawOrderAndIsByteStable() async throws {
        let r = await Draw.draw(repos: Draw.repos(fromPackageList: list), spec: spec(), excluding: [], check: eligible)
        let again = await Draw.draw(repos: Draw.repos(fromPackageList: list.reversed()), spec: spec(), excluding: [], check: eligible)
        let a = try CorpusYAML.encode(CorpusManifest(packages: r.packages), header: "# h\n")
        let b = try CorpusYAML.encode(CorpusManifest(packages: again.packages), header: "# h\n")
        #expect(a == b)
        #expect(a.hasPrefix("# h\n"))
        // Draw order (o/r18 before o/r12), not sorted order.
        #expect(a.range(of: "o/r18")!.lowerBound < a.range(of: "o/r12")!.lowerBound)
    }

    @Test func metadataRulesArePreRegistered() {
        let now = ISO8601DateFormatter().date(from: "2026-10-10T00:00:00Z")!
        #expect(Draw.checkMetadata("false\tfalse\t2026-09-01T00:00:00Z\tmain\n", now: now, activeDays: 365) == .active(branch: "main"))
        #expect(Draw.checkMetadata("true\tfalse\t2026-09-01T00:00:00Z\tmain", now: now, activeDays: 365) == .rejected("archived or disabled"))
        #expect(Draw.checkMetadata("false\ttrue\t2026-09-01T00:00:00Z\tmain", now: now, activeDays: 365) == .rejected("archived or disabled"))
        #expect(Draw.checkMetadata("false\tfalse\t2025-10-01T00:00:00Z\tmain", now: now, activeDays: 365) == .rejected("inactive > 365d"))
        #expect(Draw.checkMetadata(nil, now: now, activeDays: 365) == .rejected("unavailable (renamed/removed)"))
        #expect(Draw.checkMetadata("garbage", now: now, activeDays: 365) == .rejected("unavailable (renamed/removed)"))
    }

    @Test func positionIsParsedFromTheSelectionString() {
        #expect(Draw.position(inSelection: "seed=1 draw-position=123 PackageList@x") == 123)
        #expect(Draw.position(inSelection: "named anchor") == nil)
    }
}
```

- [ ] **Step 2: Run the tests and watch them fail**

Run: `swift test --package-path tools --filter DrawTests`
Expected: compile error, `cannot find 'Draw' in scope`.

- [ ] **Step 3: Implement `Draw.swift`**

Create `tools/Sources/CensusRunner/Draw.swift`:

```swift
import CensusCore
import Foundation
import Yams

public enum Eligibility: Equatable, Sendable {
    case eligible(sha: String, branch: String)
    case rejected(String)
}

public struct DrawSpec: Sendable {
    public var seed: UInt64
    public var count: Int
    /// First shuffle position considered: 0 for a fresh draw, one past the last drawn position for an extension (D5).
    public var startPosition: Int
    public var packageListSHA: String
    /// The draw date, `YYYY-MM-DD`, recorded in each entry's `selection`.
    public var date: String
    public var stratum: Stratum
    public var platforms: [Platform]

    public init(seed: UInt64, count: Int, startPosition: Int, packageListSHA: String, date: String,
                stratum: Stratum, platforms: [Platform]) {
        self.seed = seed
        self.count = count
        self.startPosition = startPosition
        self.packageListSHA = packageListSHA
        self.date = date
        self.stratum = stratum
        self.platforms = platforms
    }
}

public struct DrawResult: Sendable {
    public var packages: [CorpusPackage]
    public var rejected: [String: Int]
}

/// The seeded walk over the PackageList shared by `S-control` and the screen (ADR 0007). Pure apart from `check`,
/// which is the network half of eligibility, so the order, skipping and output are testable against fixtures.
public enum Draw {
    public static func repos(fromPackageList urls: [String]) -> [String: String] {
        var byId: [String: String] = [:]
        for u in urls { if let r = Selection.githubRepo(from: u) { byId["\(r.owner)/\(r.repo)"] = r.url } }
        return byId
    }

    public static func draw(
        repos: [String: String], spec: DrawSpec, excluding: Set<String>,
        check: (_ id: String, _ url: String) async throws -> Eligibility
    ) async rethrows -> DrawResult {
        var drawn: [CorpusPackage] = []
        var rejected: [String: Int] = [:]
        for (position, id) in Selection.seededShuffle(Array(repos.keys), seed: spec.seed).enumerated()
        where position >= spec.startPosition {
            if drawn.count >= spec.count { break }
            if excluding.contains(id) { rejected["already in corpus or candidates", default: 0] += 1; continue }
            guard let url = repos[id] else { continue }
            switch try await check(id, url) {
            case .rejected(let reason):
                rejected[reason, default: 0] += 1
            case .eligible(let sha, let branch):
                drawn.append(CorpusPackage(
                    id: id, url: url, sha: sha, stratum: spec.stratum, platforms: spec.platforms,
                    selection: "seed=\(spec.seed) draw-position=\(position) PackageList@\(spec.packageListSHA) "
                        + "HEAD of \(branch) on \(spec.date)"))
            }
        }
        return DrawResult(packages: drawn, rejected: rejected)
    }

    public enum MetadataCheck: Equatable, Sendable {
        case active(branch: String)
        case rejected(String)
    }

    /// The pre-registered eligibility rule (ADR 0004 §5, ADR 0007) over GitHub's
    /// `archived \t disabled \t pushed_at \t default_branch`. `nil` means the API call failed.
    public static func checkMetadata(_ tsv: String?, now: Date, activeDays: Int) -> MetadataCheck {
        let f = (tsv ?? "").trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\t").map(String.init)
        guard tsv != nil, f.count == 4 else { return .rejected("unavailable (renamed/removed)") }
        if f[0] == "true" || f[1] == "true" { return .rejected("archived or disabled") }
        let cutoff = now.addingTimeInterval(-Double(activeDays) * 86400)
        guard let pushed = ISO8601DateFormatter().date(from: f[2]), pushed >= cutoff else {
            return .rejected("inactive > \(activeDays)d")
        }
        return .active(branch: f[3])
    }

    /// The `draw-position=` that `draw` recorded in a `selection` string. An extension resumes one past the largest.
    public static func position(inSelection s: String) -> Int? {
        guard let r = s.range(of: "draw-position=") else { return nil }
        return Int(s[r.upperBound...].prefix { $0.isNumber })
    }
}

public enum CorpusYAML {
    /// `sortKeys` orders each entry's keys deterministically (G9). Package order is the caller's: the corpus sorts,
    /// the screen keeps draw order.
    public static func encode(_ manifest: CorpusManifest, header: String) throws -> String {
        var encoder = YAMLEncoder()
        encoder.options.sortKeys = true
        encoder.options.width = 120
        return header + (try encoder.encode(manifest))
    }
}
```

- [ ] **Step 4: Run the tests and watch them pass**

Run: `swift test --package-path tools --filter DrawTests`
Expected: PASS (7 tests).

- [ ] **Step 5: Create `census/Screen.swift` with the screen paths**

Create `tools/Sources/census/Screen.swift`:

```swift
import ArgumentParser
import CensusCore
import CensusRunner
import Foundation
import Yams

/// Layout of one screen (ADR 0007): `<root>/<id>/{candidates.yaml, resolved/, results.json, emitters.csv}`.
/// Runs go under `runs/<id>-macos-bN` and `runs/<id>-macos-verify`; driver state under `work/screen-state/<id>/`.
struct ScreenPaths {
    var root: String
    var id: String

    var directory: URL { URL(fileURLWithPath: root).appendingPathComponent(id) }
    var candidates: URL { directory.appendingPathComponent("candidates.yaml") }
    var resolved: URL { directory.appendingPathComponent("resolved") }

    func loadCandidates() throws -> CorpusManifest {
        try YAMLDecoder().decode(CorpusManifest.self, from: String(contentsOf: candidates, encoding: .utf8))
    }
}

struct ScreenOptions: ParsableArguments {
    @Argument(help: "Screen id, ending in its date, e.g. screen-2026-10-10.") var id: String
    @Option(name: .long, help: "Directory holding screen directories.") var root = "screens"
    var paths: ScreenPaths { ScreenPaths(root: root, id: id) }
}
```

- [ ] **Step 6: Rewrite `Select.swift` onto `Draw`, and add `select screen`**

Replace `tools/Sources/census/Select.swift` with the following. `Emit` is unchanged apart from moving under the new helpers; Task 10 extends it.

```swift
import ArgumentParser
import CensusCore
import CensusRunner
import Foundation
import Yams

struct Select: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Draw the sampled strata into corpus/packages.yaml (A3). S-anchor and S-byproduct are named by hand.",
        subcommands: [Control.self, Emit.self, ScreenDraw.self])
}

private let packageListRepo = "SwiftPackageIndex/PackageList"
/// D2 (ADR 0007): the PackageList commit `S-control` was drawn from. The screen draws from the same frame.
let pinnedPackageListSHA = "4dc1035a98457e87f4d2c5649a33cd43ee6b80e8"

private func save(_ manifest: CorpusManifest, to url: URL, replacing stratum: Stratum, with new: [CorpusPackage]) throws {
    var m = manifest
    m.packages.removeAll { $0.stratum == stratum }
    m.packages += new
    m.packages.sort { ($0.stratum.rawValue, $0.id) < ($1.stratum.rawValue, $1.id) }
    let header = "# corpus/packages.yaml — pinned corpus (P7). Edited by `census select`; bumping a SHA is a documented operation.\n"
    try CorpusYAML.encode(m, header: header).write(to: url, atomically: true, encoding: .utf8)
}

private func headSHA(_ url: String) async throws -> String? {
    let r = try await Shell.run("git", ["ls-remote", url, "HEAD"], timeout: 60)
    guard r.succeeded else { return nil }
    let sha = r.stdoutString.split(separator: "\t").first.map(String.init) ?? ""
    return CorpusManifest.isFullSHA(sha) ? sha : nil
}

/// The PackageList at `sha`, or at `main`'s current commit when nil. Pin the *list*, not just the draw:
/// a moving PackageList would make the seed meaningless.
private func packageList(at sha: String?) async throws -> (sha: String, repos: [String: String]) {
    let listSHA: String
    if let sha {
        listSHA = sha
    } else {
        listSHA = try await Shell.check("gh", ["api", "repos/\(packageListRepo)/commits/main", "--jq", ".sha"])
            .stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    let raw = try await Shell.check("curl", ["-fsSL", "https://raw.githubusercontent.com/\(packageListRepo)/\(listSHA)/packages.json"])
    let urls = try JSONDecoder().decode([String].self, from: raw.stdout)
    let repos = Draw.repos(fromPackageList: urls)
    print("PackageList@\(listSHA.prefix(10)): \(urls.count) urls, \(repos.count) GitHub repos")
    return (listSHA, repos)
}

/// The network half of eligibility; `Draw.checkMetadata` is the rule.
private func eligibility(id: String, url: String, now: Date, activeDays: Int) async throws -> Eligibility {
    let meta = try await Shell.run("gh", ["api", "repos/\(id)", "--jq", "[.archived, .disabled, .pushed_at, .default_branch] | @tsv"])
    switch Draw.checkMetadata(meta.succeeded ? meta.stdoutString : nil, now: now, activeDays: activeDays) {
    case .rejected(let reason):
        return .rejected(reason)
    case .active(let branch):
        guard let sha = try await headSHA(url) else { return .rejected("no HEAD sha") }
        print("  eligible \(id)")
        return .eligible(sha: sha, branch: branch)
    }
}

private func today() -> String { String(ISO8601DateFormatter().string(from: Date()).prefix(10)) }

extension Select {
    struct Control: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "S-control: a seeded uniform draw from the SPI PackageList, unconditioned on diagnostic count.")

        @Option(name: .long, help: "PRNG seed. Recorded in each entry's `selection`.") var seed: UInt64
        @Option(name: .long, help: "Entries to draw.") var count = 30
        @Option(name: .long, help: "Treat repos with no push in this many days as inactive.") var activeDays = 365

        func run() async throws {
            let paths = Paths()
            let manifest = try paths.loadManifest()
            let (listSHA, repos) = try await packageList(at: nil)
            let now = Date()
            let spec = DrawSpec(seed: seed, count: count, startPosition: 0, packageListSHA: listSHA, date: today(),
                                stratum: .control, platforms: [.linuxSPM])
            let result = try await Draw.draw(repos: repos, spec: spec, excluding: Set(manifest.packages.map(\.id))) { id, url in
                try await eligibility(id: id, url: url, now: now, activeDays: activeDays)
            }
            print("rejected before the draw completed: \(result.rejected)")
            try save(manifest, to: paths.corpus, replacing: .control, with: result.packages)
        }
    }

    /// ADR 0007 §5.1. Continues `S-control`'s seeded order over the same PackageList commit, skipping every id
    /// already in the corpus. Written in draw order, because batches are positional (an extension only appends).
    struct ScreenDraw: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "screen",
            abstract: "Draw screen candidates into <root>/<screen-id>/candidates.yaml (ADR 0007).")

        @Option(name: .long, help: "Screen id, ending in its date, e.g. screen-2026-10-10.") var screenId: String
        @Option(name: .long, help: "Directory holding screen directories.") var root = "screens"
        @Option(name: .long, help: "PRNG seed (pre-registered: 20261004).") var seed: UInt64
        @Option(name: .long, help: "Candidates to draw.") var count = 300
        @Option(name: .long, help: "Treat repos with no push in this many days of the draw date as inactive.") var activeDays = 365
        @Option(name: .long, help: "PackageList commit (D2).") var packageListSha = pinnedPackageListSHA
        @Flag(name: .long, help: "D5: append --count more after the last drawn position instead of drawing afresh.") var extend = false

        func run() async throws {
            let corpus = try Paths().loadManifest()
            let sp = ScreenPaths(root: root, id: screenId)
            let fm = FileManager.default
            var candidates = CorpusManifest(packages: [])
            if fm.fileExists(atPath: sp.candidates.path) {
                guard extend else { throw ValidationError("\(sp.candidates.path) exists and is pinned; --extend appends to it (D5)") }
                candidates = try sp.loadCandidates()
            } else if extend {
                throw ValidationError("--extend needs an existing \(sp.candidates.path)")
            }
            let start = candidates.packages.compactMap { Draw.position(inSelection: $0.selection) }.max().map { $0 + 1 } ?? 0
            let (listSHA, repos) = try await packageList(at: packageListSha)
            let now = Date()
            let spec = DrawSpec(seed: seed, count: count, startPosition: start, packageListSHA: listSHA, date: today(),
                                stratum: .screen, platforms: [.macosSPM])
            let excluded = Set(corpus.packages.map(\.id)).union(candidates.packages.map(\.id))
            let result = try await Draw.draw(repos: repos, spec: spec, excluding: excluded) { id, url in
                try await eligibility(id: id, url: url, now: now, activeDays: activeDays)
            }
            print("drew \(result.packages.count) of \(count) from position \(start); rejected: \(result.rejected)")
            candidates.packages += result.packages
            try fm.createDirectory(at: sp.directory, withIntermediateDirectories: true)
            let header = "# Screen candidates (ADR 0007), in draw order. Written by `census select screen`; pinned like the corpus.\n"
            try CorpusYAML.encode(candidates, header: header).write(to: sp.candidates, atomically: true, encoding: .utf8)
        }
    }

    struct Emit: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "S-emit: sample across SPI's data-race count distribution from a supplied export (corpus/spi-counts.csv).",
            discussion: "Columns: package_url,data_race_errors,swift_version,as_of. The data must come from SPI's own published figures.")

        @Option(name: .long, help: "SPI export.") var spiData = "corpus/spi-counts.csv"
        @Option(name: .long) var seed: UInt64
        @Option(name: .long) var count = 30

        func run() async throws {
            let paths = Paths()
            let manifest = try paths.loadManifest()
            let rows = try Selection.parseSPICSV(String(contentsOfFile: spiData, encoding: .utf8))
            let sample = Selection.sampleAcrossDistribution(rows: rows, count: count, seed: seed)
            let date = today()
            var drawn: [CorpusPackage] = []
            for (row, tertile) in sample {
                guard let r = Selection.githubRepo(from: row.url) else { print("skip non-GitHub: \(row.url)"); continue }
                guard let sha = try await headSHA(r.url) else { print("skip (no HEAD): \(row.url)"); continue }
                drawn.append(CorpusPackage(
                    id: "\(r.owner)/\(r.repo)", url: r.url, sha: sha, stratum: .emit, platforms: [.linuxSPM],
                    selection: "seed=\(seed) \(tertile.rawValue)-tertile of \(rows.filter { $0.errors > 0 }.count) emitting; "
                        + "SPI \(row.swiftVersion) as of \(row.asOf); HEAD on \(date)",
                    spiErrorCountAtSelection: row.errors))
            }
            print("drew \(drawn.count) of \(sample.count) requested from \(rows.count) rows")
            try save(manifest, to: paths.corpus, replacing: .emit, with: drawn)
        }
    }
}
```

- [ ] **Step 7: Build, run all tests, and check that the corpus file round-trips unchanged**

Run:
```bash
swift build --package-path tools && swift test --package-path tools
tools/.build/debug/census select screen --help
tools/.build/debug/census validate
git diff --stat corpus/
```
Expected: build and tests pass. Help lists `--screen-id`, `--seed`, `--count`, `--extend`. `validate` exits 0. `git diff --stat corpus/` is empty (nothing in this step writes the corpus).

- [ ] **Step 8: Commit**

```bash
git add tools/Sources/CensusRunner/Draw.swift tools/Sources/census/Screen.swift tools/Sources/census/Select.swift tools/Tests/CensusRunnerTests/DrawTests.swift
git commit -m "Factor the seeded draw out of select control; add select screen" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: `--manifest`/`--resolved` on run, resolve and scan; resumable resolve

**Files:**
- Modify: `tools/Sources/census/Census.swift` (`Resolve`, `Run`, `Scan`; new `CorpusOptions`)
- Modify: `tools/Sources/CensusRunner/Resolver.swift` (new static `pending`)
- Test: `tools/Tests/CensusRunnerTests/ResolverTests.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces:
  - `Resolver.pending(_ packages: [CorpusPackage], resolvedDirectory: URL, provenance: [String: ResolvedProvenance], force: Bool) -> [CorpusPackage]`.
  - `CorpusOptions` (`--manifest`, default `corpus/packages.yaml`; `--resolved`, default `corpus/resolved`; `var paths: Paths`).
  - `census resolve --force --allow-failures`. Failures are recorded in `<resolved>/failures.json` as `[id: reason]`.

- [ ] **Step 1: Write the failing test**

Create `tools/Tests/CensusRunnerTests/ResolverTests.swift`:

```swift
import CensusCore
import Foundation
import Testing

@testable import CensusRunner

@Suite struct ResolverPendingTests {
    func pkg(_ id: String) -> CorpusPackage {
        CorpusPackage(id: id, url: "https://github.com/\(id)", sha: String(repeating: "a", count: 40),
                      stratum: .screen, platforms: [.macosSPM], selection: "t")
    }
    let prov = ResolvedProvenance(source: "upstream", toolchain: "6.4", resolvedAt: "x", sha256: "y", pinCount: 0)

    /// G3: a package is done only when both its file and its provenance entry exist; anything else is retried.
    @Test func skipsOnlyFullyVendoredPackagesUnlessForced() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("resolver-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("{}".utf8).write(to: dir.appendingPathComponent("o__done.resolved"))
        try Data("{}".utf8).write(to: dir.appendingPathComponent("o__fileonly.resolved"))
        let all = [pkg("o/done"), pkg("o/fileonly"), pkg("o/provonly"), pkg("o/new")]
        let provenance = ["o/done": prov, "o/provonly": prov]
        let pending = Resolver.pending(all, resolvedDirectory: dir, provenance: provenance, force: false)
        #expect(pending.map(\.id) == ["o/fileonly", "o/provonly", "o/new"])
        #expect(Resolver.pending(all, resolvedDirectory: dir, provenance: provenance, force: true).count == 4)
    }
}
```

- [ ] **Step 2: Run it and watch it fail**

Run: `swift test --package-path tools --filter ResolverPendingTests`
Expected: compile error, `type 'Resolver' has no member 'pending'`.

- [ ] **Step 3: Implement `Resolver.pending`**

Add inside `public struct Resolver` in `tools/Sources/CensusRunner/Resolver.swift`:

```swift
    /// G3: resume-safe. A package is done when its vendored file exists *and* provenance records it. Anything else
    /// (never tried, failed, or interrupted between the two writes) is pending. `force` re-resolves everything,
    /// which for the corpus is a documented operation with a fresh baseline run, never a drive-by.
    public static func pending(_ packages: [CorpusPackage], resolvedDirectory: URL,
                               provenance: [String: ResolvedProvenance], force: Bool) -> [CorpusPackage] {
        guard !force else { return packages }
        return packages.filter { p in
            provenance[p.id] == nil
                || !FileManager.default.fileExists(atPath: resolvedDirectory.appendingPathComponent("\(p.slug).resolved").path)
        }
    }
```

- [ ] **Step 4: Run the test and watch it pass**

Run: `swift test --package-path tools --filter ResolverPendingTests`
Expected: PASS.

- [ ] **Step 5: Add `CorpusOptions` and wire it into `Resolve`, `Run` and `Scan`**

In `tools/Sources/census/Census.swift`, add after `struct Paths`:

```swift
/// `--manifest`/`--resolved` let the screen (ADR 0007) keep its candidates outside `corpus/`. Defaults are the corpus.
struct CorpusOptions: ParsableArguments {
    @Option(name: .long, help: "Corpus manifest.") var manifest = "corpus/packages.yaml"
    @Option(name: .long, help: "Directory of vendored Package.resolved files.") var resolved = "corpus/resolved"
    var paths: Paths { Paths(corpus: URL(fileURLWithPath: manifest), resolved: URL(fileURLWithPath: resolved)) }
}
```

Replace `struct Resolve` with:

```swift
struct Resolve: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Vendor a Package.resolved per corpus entry (F1). A documented operation, never a drive-by.",
        discussion: "Skips packages already vendored (G3); --force re-resolves them.")

    @OptionGroup var corpus: CorpusOptions
    @Option(name: .long, help: "Toolchain used to resolve.") var toolchain = "6.4"
    @Option(name: .long, parsing: .upToNextOption, help: "Only these package ids.") var package: [String] = []
    @Flag(name: .long, help: "Re-resolve packages that already have a vendored file.") var force = false
    @Flag(name: .long, help: "Record failures in failures.json and exit 0: the screen's unresolvable candidates are data.") var allowFailures = false

    func run() async throws {
        let paths = corpus.paths
        let manifest = try paths.loadManifest()
        guard let tc = Toolchain.named(toolchain) else { throw ValidationError("unknown toolchain \(toolchain)") }
        try FileManager.default.createDirectory(at: paths.scratch, withIntermediateDirectories: true)
        let resolver = Resolver(sources: paths.sources, resolvedDirectory: paths.resolved, scratch: paths.scratch, toolchain: tc)
        let store = RunStore(root: paths.resolved)

        let provenanceURL = paths.resolved.appendingPathComponent("provenance.json")
        let failuresURL = paths.resolved.appendingPathComponent("failures.json")
        var provenance = (try? JSONDecoder().decode([String: ResolvedProvenance].self, from: Data(contentsOf: provenanceURL))) ?? [:]
        var failed = (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: failuresURL))) ?? [:]
        let selected = manifest.packages.filter { $0.skipReason == nil && (package.isEmpty || package.contains($0.id)) }
        let pending = Resolver.pending(selected, resolvedDirectory: paths.resolved, provenance: provenance, force: force)
        print("\(pending.count) to resolve (\(selected.count - pending.count) already vendored)")
        var failures = 0
        for p in pending {
            do {
                let result = try await resolver.resolve(p)
                provenance[p.id] = result
                failed[p.id] = nil
                print("resolved \(p.id): \(result.source), \(result.pinCount) pins")
            } catch {
                failures += 1
                failed[p.id] = "\(error)"
                print("FAILED \(p.id): \(error)")
            }
            try store.write(provenance, to: provenanceURL)
            if failed.isEmpty { try? FileManager.default.removeItem(at: failuresURL) } else { try store.write(failed, to: failuresURL) }
        }
        if failures > 0 && !allowFailures { throw ExitCode.failure }
    }
}
```

In `struct Run`, add `@OptionGroup var corpus: CorpusOptions` as the first property and replace `let paths = Paths()` with `let paths = corpus.paths`.

In `struct Scan`, add `@OptionGroup var corpus: CorpusOptions` as the first property and replace `let paths = Paths()` with `let paths = corpus.paths`.

- [ ] **Step 6: Build, test, and smoke-test the defaults**

Run:
```bash
swift build --package-path tools && swift test --package-path tools
tools/.build/debug/census resolve --help | grep -E "manifest|resolved|force|allow-failures"
tools/.build/debug/census run --help | grep -E "manifest|resolved"
tools/.build/debug/census scan --help | grep -E "manifest|resolved"
```
Expected: all pass, and every grep matches. Do **not** run `census resolve` against the corpus here (it needs Docker, and with the new skip-if-present it would only report "0 to resolve").

- [ ] **Step 7: Commit**

```bash
git add tools/Sources/census/Census.swift tools/Sources/CensusRunner/Resolver.swift tools/Tests/CensusRunnerTests/ResolverTests.swift
git commit -m "Add --manifest/--resolved; make resolve skip vendored packages and record failures" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7: The screen's pure core — count, status, stability, denominator, export, batches

**Files:**
- Create: `tools/Sources/CensusRunner/Screen.swift`
- Modify: `tools/Sources/CensusRunner/RunStore.swift` (public init on `CellKey`)
- Test: `tools/Tests/CensusRunnerTests/ScreenTests.swift`

**Interfaces:**
- Consumes: `Mode.minimalV5` (Task 2), `Stratum.screen` (Task 3), `RunStore.LoadedCell`, `PlannedCell`, `Toolchain.macOSXcode`, `Selection.parseSPICSV`.
- Produces:
  - `RunStore.CellKey.init(toolchain: String, mode: Mode, packageId: String)` (public).
  - `enum ScreenStatus: String, Codable, Sendable, CaseIterable`: `emitter`, `clean`, `notScreenable = "not_screenable"`, `minimalFailed = "minimal_failed"`, `unresolvable`, `infraError = "infra_error"`, `unstable`.
  - `struct ScreenResult: Codable, Equatable, Sendable` with fields `packageId, sha, status, reason?, completeOutcome?, minimalOutcome?, completePrimaryDiagnostics?, minimalPrimaryDiagnostics?, screenCount?, batch, verifyScreenCount?` and the initializer `init(packageId:sha:status:reason:=nil, completeOutcome:=nil, minimalOutcome:=nil, completePrimaryDiagnostics:=nil, minimalPrimaryDiagnostics:=nil, screenCount:=nil, batch:, verifyScreenCount:=nil)`.
  - `enum ScreenError: Error, CustomStringConvertible, Equatable`: `incomplete(String, String)`, `denominatorMismatch(drawn: Int, sum: Int)`, `resolvedMismatch(String)`, `unverified(String)`.
  - `struct Denominator: Equatable, Sendable { drawn; byStatus: [ScreenStatus: Int]; notScreenableByReason: [String: Int]; var total: Int; var rendered: String }`.
  - `Screen.batchSize` (50), `Screen.toolchain` (`Toolchain.macOSXcode`), `Screen.swiftVersionLabel` (`"xcode-27.0-minimal-diff"`).
  - `Screen.primaryDiagnostics(_:) -> Int`, `Screen.screenCount(complete:minimal:) -> Int`, `Screen.needsMinimal(_: RunStore.LoadedCell) -> Bool`.
  - `Screen.batchCount(_ total: Int) -> Int`, `Screen.batch<T>(_ n: Int, of: [T]) -> [T]`, `Screen.cells(_: [CorpusPackage], mode: Mode) -> [PlannedCell]`.
  - `Screen.classify(package:batch:resolveFailure:complete:minimal:) throws -> ScreenResult`, `Screen.applyVerify(_:package:complete:minimal:) throws -> ScreenResult`, `Screen.verifyPackages(results:candidates:) -> [CorpusPackage]`.
  - `Screen.denominator(drawn:results:) throws -> Denominator`, `Screen.emittersCSV(results:candidates:asOf:) -> String`, `Screen.date(fromScreenId:) -> String?`.

- [ ] **Step 1: Write the failing tests**

Create `tools/Tests/CensusRunnerTests/ScreenTests.swift`:

```swift
import CensusCore
import Foundation
import Testing

@testable import CensusRunner

private func diag(_ id: String?, line: Int = 1, text: String = "t", severity: Severity = .warning,
                  attribution: Attribution = .primary) -> DiagnosticRecord {
    DiagnosticRecord(id: id, text: text, severity: severity, group: nil, groupURL: nil, path: "Sources/A/a.swift",
                     line: line, col: 1, fixIts: 0, attribution: attribution, parent: nil)
}

private func pkg(_ id: String) -> CorpusPackage {
    CorpusPackage(id: id, url: "https://github.com/\(id)", sha: String(repeating: "c", count: 40),
                  stratum: .screen, platforms: [.macosSPM], selection: "t")
}

private func cell(_ id: String = "o/r", _ mode: Mode, _ outcome: CellOutcome, _ diags: [DiagnosticRecord] = [],
                  note: String? = nil) -> RunStore.LoadedCell {
    var r = CellRecord(packageId: id, sha: String(repeating: "c", count: 40), stratum: .screen, toolchain: "xcode-27.0",
                       mode: mode, platform: .macosSPM, outcome: outcome, exitCode: 0, startedAt: "", durationSeconds: 0,
                       invocation: [], image: "")
    r.note = note
    return RunStore.LoadedCell(record: r, diagnostics: diags, directory: URL(fileURLWithPath: "/"))
}

@Suite struct ScreenCountTests {
    @Test func identicalBuildsCountZero() {
        let d = [diag("a"), diag("b", line: 2)]
        #expect(Screen.screenCount(complete: d, minimal: d) == 0)
    }

    @Test func countsWhatCompleteAdds() {
        let base = [diag("a")]
        #expect(Screen.screenCount(complete: base + [diag("x", line: 2), diag("y", line: 3), diag("z", line: 4)], minimal: base) == 3)
    }

    @Test func aMovedLineCountsAsAdded() {
        #expect(Screen.screenCount(complete: [diag("a", line: 2)], minimal: [diag("a", line: 1)]) == 1)
    }

    @Test func isAMultisetDifferenceLeftMinusRight() {
        #expect(Screen.screenCount(complete: [diag("a"), diag("a")], minimal: [diag("a")]) == 1)
        #expect(Screen.screenCount(complete: [], minimal: [diag("a")]) == 0)
    }

    @Test func notesAndNonPrimaryAreIgnored() {
        let ignored = [diag("n", line: 9, severity: .note), diag("d", attribution: .transitive),
                       diag("g", attribution: .generated), diag("e", attribution: .external)]
        #expect(Screen.screenCount(complete: ignored, minimal: []) == 0)
    }

    /// Unlike the A7 key, severity is not part of the count key (ADR 0007).
    @Test func aSeverityChangeBetweenModesIsNotADifference() {
        #expect(Screen.screenCount(complete: [diag("a", severity: .error)], minimal: [diag("a", severity: .warning)]) == 0)
    }

    @Test func isOrderIndependent() {
        let c = [diag("a"), diag("b", line: 2), diag("c", line: 3)]
        #expect(Screen.screenCount(complete: c, minimal: [diag("b", line: 2)])
            == Screen.screenCount(complete: c.reversed(), minimal: [diag("b", line: 2)]))
    }

    @Test func aMissingIdFallsBackToText() {
        #expect(Screen.screenCount(complete: [diag(nil, text: "x")], minimal: [diag(nil, text: "y")]) == 1)
        #expect(Screen.screenCount(complete: [diag(nil, text: "x")], minimal: [diag(nil, text: "x")]) == 0)
    }
}

@Suite struct ScreenClassificationTests {
    let p = pkg("o/r")

    @Test func emitter() throws {
        let r = try Screen.classify(package: p, batch: 2, resolveFailure: nil,
                                    complete: cell(.strictCompleteV5, .built, [diag("a"), diag("b", line: 2)]),
                                    minimal: cell(.minimalV5, .built, [diag("a")]))
        #expect(r.status == .emitter && r.screenCount == 1 && r.batch == 2 && r.sha == p.sha)
        #expect(r.completePrimaryDiagnostics == 2 && r.minimalPrimaryDiagnostics == 1)
        #expect(r.completeOutcome == .built && r.minimalOutcome == .built)
    }

    @Test func cleanWithNoPrimaryDiagnosticsNeedsNoMinimalBuild() throws {
        let complete = cell(.strictCompleteV5, .built, [diag("n", severity: .note), diag("d", attribution: .transitive)])
        #expect(!Screen.needsMinimal(complete))
        let r = try Screen.classify(package: p, batch: 1, resolveFailure: nil, complete: complete, minimal: nil)
        #expect(r.status == .clean && r.screenCount == 0 && r.minimalOutcome == nil)
    }

    @Test func cleanWhenMinimalAlreadyHasEverything() throws {
        let d = [diag("a")]
        #expect(Screen.needsMinimal(cell(.strictCompleteV5, .built, d)))
        let r = try Screen.classify(package: p, batch: 1, resolveFailure: nil,
                                    complete: cell(.strictCompleteV5, .built, d), minimal: cell(.minimalV5, .built, d))
        #expect(r.status == .clean && r.screenCount == 0)
    }

    @Test(arguments: [CellOutcome.buildFailed, .unsupportedToolsVersion, .resolveFailed, .timeout])
    func notScreenableKeepsReasonAndTally(outcome: CellOutcome) throws {
        let complete = cell(.strictCompleteV5, outcome, [diag("a")])
        #expect(!Screen.needsMinimal(complete))
        let r = try Screen.classify(package: p, batch: 1, resolveFailure: nil, complete: complete, minimal: nil)
        #expect(r.status == .notScreenable && r.reason == outcome.rawValue)
        #expect(r.completePrimaryDiagnostics == 1 && r.screenCount == nil)
    }

    @Test func minimalFailed() throws {
        let r = try Screen.classify(package: p, batch: 1, resolveFailure: nil,
                                    complete: cell(.strictCompleteV5, .built, [diag("a")]), minimal: cell(.minimalV5, .buildFailed))
        #expect(r.status == .minimalFailed && r.reason == "build_failed" && r.screenCount == nil)
    }

    @Test func unresolvable() throws {
        let r = try Screen.classify(package: p, batch: 3, resolveFailure: "o/r: dependency resolution failed", complete: nil, minimal: nil)
        #expect(r.status == .unresolvable && r.reason == "o/r: dependency resolution failed" && r.completeOutcome == nil && r.batch == 3)
    }

    @Test func infraErrorOnEitherCell() throws {
        let a = try Screen.classify(package: p, batch: 1, resolveFailure: nil,
                                    complete: cell(.strictCompleteV5, .infraError, note: "corrupt .dia"), minimal: nil)
        #expect(a.status == .infraError && a.reason == "corrupt .dia")
        let b = try Screen.classify(package: p, batch: 1, resolveFailure: nil,
                                    complete: cell(.strictCompleteV5, .built, [diag("a")]), minimal: cell(.minimalV5, .infraError))
        #expect(b.status == .infraError)
    }

    @Test func aMissingCellIsAnErrorNeverASilentGap() {
        #expect(throws: ScreenError.self) {
            try Screen.classify(package: p, batch: 1, resolveFailure: nil, complete: nil, minimal: nil)
        }
        #expect(throws: ScreenError.self) {
            try Screen.classify(package: p, batch: 1, resolveFailure: nil, complete: cell(.strictCompleteV5, .built, [diag("a")]), minimal: nil)
        }
    }
}

@Suite struct ScreenStabilityTests {
    let p = pkg("o/r")
    func pass1() throws -> ScreenResult {
        try Screen.classify(package: p, batch: 1, resolveFailure: nil,
                            complete: cell(.strictCompleteV5, .built, [diag("a"), diag("b", line: 2)]), minimal: cell(.minimalV5, .built, [diag("a")]))
    }

    @Test func agreeingVerifyPassStaysAnEmitter() throws {
        let r = try Screen.applyVerify(try pass1(), package: p,
                                       complete: cell(.strictCompleteV5, .built, [diag("a"), diag("b", line: 2)]),
                                       minimal: cell(.minimalV5, .built, [diag("a")]))
        #expect(r.status == .emitter && r.verifyScreenCount == 1)
    }

    @Test func aDifferentCountIsUnstable() throws {
        let r = try Screen.applyVerify(try pass1(), package: p,
                                       complete: cell(.strictCompleteV5, .built, [diag("a"), diag("b", line: 2), diag("c", line: 3)]),
                                       minimal: cell(.minimalV5, .built, [diag("a")]))
        #expect(r.status == .unstable && r.verifyScreenCount == 2 && r.screenCount == 1)
    }

    @Test func aDifferentOutcomeIsUnstable() throws {
        let r = try Screen.applyVerify(try pass1(), package: p, complete: cell(.strictCompleteV5, .buildFailed, [diag("a")]), minimal: nil)
        #expect(r.status == .unstable)
    }

    @Test func nonEmittersAreReturnedUnchanged() throws {
        let clean = ScreenResult(packageId: "o/r", sha: "", status: .clean, screenCount: 0, batch: 1)
        #expect(try Screen.applyVerify(clean, package: p, complete: nil, minimal: nil) == clean)
    }

    @Test func aMissingVerifyCellIsAnError() {
        #expect(throws: ScreenError.self) { try Screen.applyVerify(try pass1(), package: p, complete: nil, minimal: nil) }
    }

    @Test func verifyPassCoversPassOneEmittersInCandidateOrder() {
        let cands = [pkg("o/a"), pkg("o/b"), pkg("o/c"), pkg("o/d")]
        let rs = [ScreenResult(packageId: "o/c", sha: "", status: .unstable, batch: 1),
                  ScreenResult(packageId: "o/a", sha: "", status: .emitter, batch: 1),
                  ScreenResult(packageId: "o/b", sha: "", status: .clean, batch: 1),
                  ScreenResult(packageId: "o/d", sha: "", status: .notScreenable, batch: 1)]
        #expect(Screen.verifyPackages(results: rs, candidates: cands).map(\.id) == ["o/a", "o/c"])
    }
}

@Suite struct ScreenBookkeepingTests {
    func res(_ id: String, _ s: ScreenStatus, reason: String? = nil, count: Int? = nil) -> ScreenResult {
        ScreenResult(packageId: id, sha: "", status: s, reason: reason, screenCount: count, batch: 1)
    }

    @Test func everyStatusIsCountedAndTheTableSumsToTheDraw() throws {
        let rs = ScreenStatus.allCases.enumerated().map { i, s in res("o/\(i)", s, reason: s == .notScreenable ? "build_failed" : nil) }
        let d = try Screen.denominator(drawn: rs.count, results: rs)
        #expect(d.total == rs.count)
        for s in ScreenStatus.allCases { #expect(d.byStatus[s] == 1) }
        #expect(d.notScreenableByReason == ["build_failed": 1])
        for s in ScreenStatus.allCases { #expect(d.rendered.contains(s.rawValue)) }
        #expect(d.rendered.contains("build_failed"))
    }

    @Test func aMissingOrDuplicatedCandidateFailsTheAssertion() {
        #expect(throws: ScreenError.self) { try Screen.denominator(drawn: 3, results: [res("o/a", .clean), res("o/b", .emitter)]) }
        #expect(throws: ScreenError.self) { try Screen.denominator(drawn: 2, results: [res("o/a", .clean), res("o/a", .clean)]) }
    }

    @Test func emittersCSVRoundTripsThroughTheSPIParserAndOmitsUnstable() throws {
        let cands = [pkg("o/a"), pkg("o/b"), pkg("o/c")]
        let rs = [res("o/a", .emitter, count: 7), res("o/b", .clean, count: 0), res("o/c", .unstable, count: 4)]
        let rows = try Selection.parseSPICSV(Screen.emittersCSV(results: rs, candidates: cands, asOf: "2026-10-10"))
        #expect(rows == [SPIRow(url: "https://github.com/o/a", errors: 7, swiftVersion: "xcode-27.0-minimal-diff", asOf: "2026-10-10")])
    }

    @Test func screenDateComesFromTheId() {
        #expect(Screen.date(fromScreenId: "screen-2026-10-10") == "2026-10-10")
        #expect(Screen.date(fromScreenId: "dryrun-2026-10-10") == "2026-10-10")
        #expect(Screen.date(fromScreenId: "screen") == nil)
        #expect(Screen.date(fromScreenId: "screen-2026-1x-10") == nil)
    }

    /// Batch membership depends only on position, so a D5 extension never changes a full earlier batch.
    @Test func batchesArePositionalSoAnExtensionOnlyAppends() {
        let items = Array(0..<120)
        #expect(Screen.batchCount(120) == 3 && Screen.batchCount(100) == 2 && Screen.batchCount(0) == 0)
        #expect(Screen.batch(1, of: items) == Array(0..<50))
        #expect(Screen.batch(3, of: items) == Array(100..<120))
        #expect(Screen.batch(4, of: items).isEmpty && Screen.batch(0, of: items).isEmpty)
        let extended = items + Array(120..<270)
        for n in 1...2 { #expect(Screen.batch(n, of: extended) == Screen.batch(n, of: items)) }
    }

    @Test func cellsUseTheScreenToolchainAndTheRequestedMode() {
        let cells = Screen.cells([pkg("o/a"), pkg("o/b")], mode: .minimalV5)
        #expect(cells.map(\.package.id) == ["o/a", "o/b"])
        #expect(cells.allSatisfy { $0.mode == .minimalV5 && $0.toolchain == Toolchain.macOSXcode })
    }
}
```

- [ ] **Step 2: Run the tests and watch them fail**

Run: `swift test --package-path tools --filter "ScreenCountTests|ScreenClassificationTests|ScreenStabilityTests|ScreenBookkeepingTests"`
Expected: compile error, `cannot find 'Screen' in scope`.

- [ ] **Step 3: Make `CellKey` constructible outside the module**

In `tools/Sources/CensusRunner/RunStore.swift`, inside `public struct CellKey`, add:

```swift
        public init(toolchain: String, mode: Mode, packageId: String) {
            self.toolchain = toolchain
            self.mode = mode
            self.packageId = packageId
        }
```

- [ ] **Step 4: Implement `Screen.swift`**

Create `tools/Sources/CensusRunner/Screen.swift`:

```swift
import CensusCore
import Foundation

/// ADR 0007 §5.4. Every drawn candidate ends in exactly one of these, and the denominator table sums them.
public enum ScreenStatus: String, Codable, Sendable, CaseIterable {
    case emitter
    case clean
    case notScreenable = "not_screenable"
    case minimalFailed = "minimal_failed"
    case unresolvable
    case infraError = "infra_error"
    case unstable
}

public struct ScreenResult: Codable, Equatable, Sendable {
    public var packageId: String
    public var sha: String
    public var status: ScreenStatus
    public var reason: String?
    /// Nil only for `unresolvable`: no cell was built.
    public var completeOutcome: CellOutcome?
    public var minimalOutcome: CellOutcome?
    public var completePrimaryDiagnostics: Int?
    public var minimalPrimaryDiagnostics: Int?
    public var screenCount: Int?
    public var batch: Int
    /// The verify pass's count (§5.6), set for pass-1 emitters once the verify pass is collected.
    public var verifyScreenCount: Int?

    enum CodingKeys: String, CodingKey {
        case packageId = "package_id", sha, status, reason
        case completeOutcome = "complete_outcome", minimalOutcome = "minimal_outcome"
        case completePrimaryDiagnostics = "complete_primary_diagnostics"
        case minimalPrimaryDiagnostics = "minimal_primary_diagnostics"
        case screenCount = "screen_count", batch
        case verifyScreenCount = "verify_screen_count"
    }

    public init(packageId: String, sha: String, status: ScreenStatus, reason: String? = nil,
                completeOutcome: CellOutcome? = nil, minimalOutcome: CellOutcome? = nil,
                completePrimaryDiagnostics: Int? = nil, minimalPrimaryDiagnostics: Int? = nil,
                screenCount: Int? = nil, batch: Int, verifyScreenCount: Int? = nil) {
        self.packageId = packageId
        self.sha = sha
        self.status = status
        self.reason = reason
        self.completeOutcome = completeOutcome
        self.minimalOutcome = minimalOutcome
        self.completePrimaryDiagnostics = completePrimaryDiagnostics
        self.minimalPrimaryDiagnostics = minimalPrimaryDiagnostics
        self.screenCount = screenCount
        self.batch = batch
        self.verifyScreenCount = verifyScreenCount
    }
}

public enum ScreenError: Error, CustomStringConvertible, Equatable {
    case incomplete(String, String)
    case denominatorMismatch(drawn: Int, sum: Int)
    case resolvedMismatch(String)
    case unverified(String)

    public var description: String {
        switch self {
        case .incomplete(let id, let what): "\(id): \(what)"
        case .denominatorMismatch(let drawn, let sum): "denominator sums to \(sum), but \(drawn) were drawn"
        case .resolvedMismatch(let id): "\(id): corpus/resolved already holds a different file; refusing to overwrite a pinned graph"
        case .unverified(let id): "\(id): emitter has no verify-pass count; run `census screen collect --with-verify` first (§5.6)"
        }
    }
}

public struct Denominator: Equatable, Sendable {
    public var drawn: Int
    public var byStatus: [ScreenStatus: Int]
    public var notScreenableByReason: [String: Int]
    public var total: Int { byStatus.values.reduce(0, +) }

    static let order: [ScreenStatus] = [.unresolvable, .notScreenable, .clean, .emitter, .unstable, .minimalFailed, .infraError]

    public var rendered: String {
        var lines = ["drawn            \(drawn)"]
        for s in Self.order {
            lines.append(s.rawValue.padding(toLength: 17, withPad: " ", startingAt: 0) + "\(byStatus[s] ?? 0)")
            if s == .notScreenable {
                for (reason, n) in notScreenableByReason.sorted(by: { $0.key < $1.key }) {
                    lines.append("  " + reason.padding(toLength: 15, withPad: " ", startingAt: 0) + "\(n)")
                }
            }
        }
        lines.append("sum              \(total)")
        return lines.joined(separator: "\n")
    }
}

/// The macOS screen that selects `S-emit` by measurement (ADR 0007). Pure: the commands in `census` do the I/O.
public enum Screen {
    public static let batchSize = 50
    public static let toolchain = Toolchain.macOSXcode
    /// `emitters.csv`'s `swift_version` column: which compiler and which count produced the number.
    public static let swiftVersionLabel = "xcode-27.0-minimal-diff"

    public static func primaryDiagnostics(_ records: [DiagnosticRecord]) -> Int {
        records.filter { $0.attribution == .primary && $0.severity != .note }.count
    }

    private struct Key: Hashable {
        var id: String
        var path: String
        var line: Int
        var col: Int
    }

    /// §5.3: the multiset difference `complete − minimal` over primary, non-note diagnostics.
    ///
    /// Severity is deliberately **not** in the key, unlike the A7 key (`DiagnosticKey`). A diagnostic can be a warning
    /// under `minimal` and an error under `complete`, and strict checking did not add it.
    public static func screenCount(complete: [DiagnosticRecord], minimal: [DiagnosticRecord]) -> Int {
        func counts(_ records: [DiagnosticRecord]) -> [Key: Int] {
            records.filter { $0.attribution == .primary && $0.severity != .note }.reduce(into: [:]) {
                $0[Key(id: $1.id ?? "text:\($1.text)", path: $1.path, line: $1.line, col: $1.col), default: 0] += 1
            }
        }
        let m = counts(minimal)
        return counts(complete).reduce(0) { $0 + max(0, $1.value - m[$1.key, default: 0]) }
    }

    /// §5.2 step 4, early exit: only a built complete cell with a primary diagnostic can have a non-zero count.
    public static func needsMinimal(_ complete: RunStore.LoadedCell) -> Bool {
        complete.record.outcome == .built && primaryDiagnostics(complete.diagnostics) > 0
    }

    public static func batchCount(_ total: Int) -> Int { (total + batchSize - 1) / batchSize }

    /// Batch `n` (1-based) of `items`, in their given order. Membership depends only on position, so an extension
    /// (D5) appends batches and never reshuffles a full earlier one.
    public static func batch<T>(_ n: Int, of items: [T]) -> [T] {
        let lo = (n - 1) * batchSize
        guard n >= 1, lo < items.count else { return [] }
        return Array(items[lo..<min(lo + batchSize, items.count)])
    }

    /// The screen picks its modes explicitly; `BuildInvocation.modes(for:)` never yields `minimal-v5`.
    public static func cells(_ packages: [CorpusPackage], mode: Mode) -> [PlannedCell] {
        packages.map { PlannedCell(package: $0, toolchain: toolchain, mode: mode) }
    }

    /// §5.4. Throws rather than guess when a cell the status depends on is missing.
    public static func classify(package p: CorpusPackage, batch: Int, resolveFailure: String?,
                                complete: RunStore.LoadedCell?, minimal: RunStore.LoadedCell?) throws -> ScreenResult {
        var r = ScreenResult(packageId: p.id, sha: p.sha, status: .clean, batch: batch)
        guard let complete else {
            guard let resolveFailure else {
                throw ScreenError.incomplete(p.id, "no strict-complete-v5 cell and no recorded resolve failure")
            }
            r.status = .unresolvable
            r.reason = resolveFailure
            return r
        }
        let completeCount = primaryDiagnostics(complete.diagnostics)
        r.completeOutcome = complete.record.outcome
        r.completePrimaryDiagnostics = completeCount
        switch complete.record.outcome {
        case .built:
            break
        case .infraError:
            r.status = .infraError
            r.reason = complete.record.note
            return r
        case .buildFailed, .unsupportedToolsVersion, .resolveFailed, .timeout:
            r.status = .notScreenable
            r.reason = complete.record.outcome.rawValue
            return r
        }
        guard completeCount > 0 else {
            r.screenCount = 0
            return r
        }
        guard let minimal else { throw ScreenError.incomplete(p.id, "complete has diagnostics but there is no minimal-v5 cell") }
        r.minimalOutcome = minimal.record.outcome
        r.minimalPrimaryDiagnostics = primaryDiagnostics(minimal.diagnostics)
        switch minimal.record.outcome {
        case .built:
            let n = screenCount(complete: complete.diagnostics, minimal: minimal.diagnostics)
            r.screenCount = n
            r.status = n > 0 ? .emitter : .clean
        case .infraError:
            r.status = .infraError
            r.reason = minimal.record.note
        default:
            r.status = .minimalFailed
            r.reason = minimal.record.outcome.rawValue
        }
        return r
    }

    /// §5.6. A pass-1 emitter whose verify-pass count or either cell outcome differs is `unstable`. Neither pass is
    /// preferred and nothing is averaged. Non-emitters were not re-run and are returned unchanged.
    public static func applyVerify(_ pass1: ScreenResult, package: CorpusPackage,
                                   complete: RunStore.LoadedCell?, minimal: RunStore.LoadedCell?) throws -> ScreenResult {
        guard pass1.status == .emitter else { return pass1 }
        guard complete != nil else { throw ScreenError.incomplete(pass1.packageId, "no verify-pass strict-complete-v5 cell") }
        let v = try classify(package: package, batch: pass1.batch, resolveFailure: nil, complete: complete, minimal: minimal)
        var r = pass1
        r.verifyScreenCount = v.screenCount
        if v.screenCount != pass1.screenCount || v.completeOutcome != pass1.completeOutcome || v.minimalOutcome != pass1.minimalOutcome {
            r.status = .unstable
            r.reason = "verify pass: screen_count \(v.screenCount.map(String.init) ?? "none"), "
                + "complete \(v.completeOutcome?.rawValue ?? "none"), minimal \(v.minimalOutcome?.rawValue ?? "none")"
        }
        return r
    }

    /// The verify pass re-runs pass-1 emitters, in candidate order. `unstable` is included so the list is the same
    /// whether it is read before or after `collect --with-verify` (an unstable result was a pass-1 emitter).
    public static func verifyPackages(results: [ScreenResult], candidates: [CorpusPackage]) -> [CorpusPackage] {
        let ids = Set(results.filter { $0.status == .emitter || $0.status == .unstable }.map(\.packageId))
        return candidates.filter { ids.contains($0.id) }
    }

    /// §5.5: the counts must sum to the number drawn, with one result per candidate.
    public static func denominator(drawn: Int, results: [ScreenResult]) throws -> Denominator {
        let d = Denominator(
            drawn: drawn,
            byStatus: Dictionary(grouping: results, by: \.status).mapValues(\.count),
            notScreenableByReason: Dictionary(grouping: results.filter { $0.status == .notScreenable }, by: { $0.reason ?? "unknown" })
                .mapValues(\.count))
        guard d.total == drawn, Set(results.map(\.packageId)).count == results.count else {
            throw ScreenError.denominatorMismatch(drawn: drawn, sum: Set(results.map(\.packageId)).count)
        }
        return d
    }

    /// `Selection.parseSPICSV`-compatible (§5.5). The column is named `data_race_errors` after SPI's export; here it
    /// carries `screen_count`, which counts warnings as well as errors. Unstable emitters are not exported.
    public static func emittersCSV(results: [ScreenResult], candidates: [CorpusPackage], asOf: String) -> String {
        let urls = Dictionary(candidates.map { ($0.id, $0.url) }, uniquingKeysWith: { a, _ in a })
        var out = "# data_race_errors carries screen_count (ADR 0007); swift_version names the toolchain and the count\n"
        out += "package_url,data_race_errors,swift_version,as_of\n"
        for r in results where r.status == .emitter {
            guard let url = urls[r.packageId], let n = r.screenCount else { continue }
            out += "\(url),\(n),\(swiftVersionLabel),\(asOf)\n"
        }
        return out
    }

    /// A screen id ends in its date (`screen-2026-10-10`), which becomes `emitters.csv`'s `as_of`.
    public static func date(fromScreenId id: String) -> String? {
        let s = String(id.suffix(10))
        let parts = s.split(separator: "-", omittingEmptySubsequences: false)
        guard s.count == 10, parts.map(\.count) == [4, 2, 2], parts.allSatisfy({ $0.allSatisfy(\.isNumber) }) else { return nil }
        return s
    }
}
```

- [ ] **Step 5: Run all tests**

Run: `swift test --package-path tools`
Expected: all pass (the four new suites plus every existing suite).

- [ ] **Step 6: Commit**

```bash
git add tools/Sources/CensusRunner/Screen.swift tools/Sources/CensusRunner/RunStore.swift tools/Tests/CensusRunnerTests/ScreenTests.swift
git commit -m "Screen core: differential count, status, stability, denominator, CSV, batches" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 8: `census screen batch` and `census screen batches`; a shared guest session

**Files:**
- Modify: `tools/Sources/census/Census.swift` (factor the macOS block out of `Run`; free `writeRunManifest`; register `ScreenCommand`)
- Modify: `tools/Sources/census/Screen.swift` (extend `ScreenPaths`; add `ScreenCommand`, `Batch`, `Batches`)

**Interfaces:**
- Consumes: `Screen.*` (Task 7), `CorpusOptions`/`Paths(corpus:resolved:)` (Task 6), `ScreenPaths`/`ScreenOptions` (Task 5).
- Produces:
  - `withMacGuest(runId:paths:store:timeoutMinutes:_ body: (MacCellRunner) async throws -> Void) async throws`.
  - `writeRunManifest(runId:paths:store:toolchains:platform:hostPlatform:) async throws`.
  - `ScreenPaths` gains `results`, `emitters`, `state: URL`, `runId(batch:) -> String`, `verifyRunId`, `corpusPaths: Paths`, `hasResolved(_:) -> Bool`, `resolveFailures() -> [String: String]` and `loadResults() throws -> [ScreenResult]`.
  - CLI: `census screen batch <id> <n> [--root R] [--verify] [--retry-infra] [--timeout-minutes 45]` exits **3** when `infra_error` cells remain in the batch. `census screen batches <id> [--root R] [--verify]` prints the batch count.

- [ ] **Step 1: Factor the guest session out of `Run`**

In `tools/Sources/census/Census.swift`, delete `Run`'s private `writeRunManifest` method and add these top-level functions after `CorpusOptions`:

```swift
/// Written once per run directory, before its first cell.
func writeRunManifest(runId: String, paths: Paths, store: RunStore, toolchains: [Toolchain], platform: Platform,
                      hostPlatform: String) async throws {
    let url = store.root.appendingPathComponent("run.json")
    guard !FileManager.default.fileExists(atPath: url.path) else { return }
    let commit = try? await Shell.run("git", ["rev-parse", "HEAD"]).stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
    let dirty = try? await Shell.run("git", ["status", "--porcelain", "--", "tools", "corpus"]).stdoutString
    let docker = try? await Shell.run("docker", ["version", "--format", "{{.Server.Version}}"]).stdoutString
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let manifest = RunManifest(
        runId: runId, startedAt: ISO8601DateFormatter().string(from: Date()), toolsGitCommit: commit,
        toolsGitDirty: dirty.map { !$0.isEmpty },
        corpusManifestSHA256: try MatrixRun.sha256Hex(of: paths.corpus),
        hostPlatform: hostPlatform,
        dockerServerVersion: platform == .linuxSPM ? docker : nil,
        toolchains: Dictionary(uniqueKeysWithValues: toolchains.map { ($0.name, $0.image) }),
        modes: Mode.allCases, platform: platform)
    try store.write(manifest, to: url)
}

/// One fresh clone of the golden guest for the duration of `body`, always destroyed afterwards (ADR 0006:
/// isolation is per run). `GuestVM.create()` deletes any stale clone of the same name first.
func withMacGuest(runId: String, paths: Paths, store: RunStore, timeoutMinutes: Int,
                  _ body: (MacCellRunner) async throws -> Void) async throws {
    let vm = GuestVM(runId: runId)
    print("cloning \(GuestVM.goldenName) -> \(vm.instance)")
    try await vm.create()
    let guestInfo = await vm.describe()
    print("guest:\n\(guestInfo)")
    do {
        try await writeRunManifest(
            runId: runId, paths: paths, store: store, toolchains: [Toolchain.macOSXcode], platform: .macosSPM,
            hostPlatform: "macOS guest (Lima/vz): " + guestInfo.replacingOccurrences(of: "\n", with: "; "))
        let runner = MacCellRunner(
            vm: vm, sources: paths.sources, resolvedDirectory: paths.resolved, store: store,
            scratch: paths.scratch, timeout: TimeInterval(timeoutMinutes * 60), imageID: GuestVM.restoreImageDigest())
        try await body(runner)
    } catch {
        await vm.destroy()
        throw error
    }
    await vm.destroy()
}
```

In `Run.run()`, replace the whole `if target == .macosSPM { … }` block with:

```swift
        if target == .macosSPM {
            try await withMacGuest(runId: runId, paths: paths, store: store, timeoutMinutes: timeoutMinutes) { runner in
                await MatrixRun.execute(cells: cells, runner: runner, jobs: 1, force: force,
                                        imageID: { _ in GuestVM.restoreImageDigest() }) { print($0); fflush(stdout) }
            }
            return
        }
```

Then replace the Linux `writeRunManifest` call:

```swift
        try await writeRunManifest(runId: runId, paths: paths, store: store, toolchains: toolchains, platform: target,
                                   hostPlatform: "\(ProcessInfo.processInfo.operatingSystemVersionString) (container runtime)")
```

Add `ScreenCommand.self` to `Census.configuration.subcommands`, after `Reclassify.self`.

- [ ] **Step 2: Extend `ScreenPaths` and add the commands**

In `tools/Sources/census/Screen.swift`, add these members to `struct ScreenPaths`:

```swift
    var results: URL { directory.appendingPathComponent("results.json") }
    var emitters: URL { directory.appendingPathComponent("emitters.csv") }
    var state: URL { URL(fileURLWithPath: "work/screen-state").appendingPathComponent(id) }
    func runId(batch: Int) -> String { "\(id)-macos-b\(batch)" }
    var verifyRunId: String { "\(id)-macos-verify" }
    /// The screen as a corpus: its candidates and their vendored graphs, so `Paths`-based code runs unchanged.
    var corpusPaths: Paths { Paths(corpus: candidates, resolved: resolved) }

    func hasResolved(_ p: CorpusPackage) -> Bool {
        FileManager.default.fileExists(atPath: resolved.appendingPathComponent("\(p.slug).resolved").path)
    }

    /// `census resolve --allow-failures` records these; each becomes an `unresolvable` result.
    func resolveFailures() -> [String: String] {
        (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: resolved.appendingPathComponent("failures.json")))) ?? [:]
    }

    func loadResults() throws -> [ScreenResult] {
        try JSONDecoder().decode([ScreenResult].self, from: Data(contentsOf: results))
    }
```

Append to `tools/Sources/census/Screen.swift`:

```swift
struct ScreenCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "screen",
        abstract: "The macOS screen that selects S-emit by measurement (ADR 0007).",
        subcommands: [Batch.self, Batches.self])
}

/// The packages a pass works through: every candidate for pass 1, the pass-1 emitters for the verify pass.
private func pool(_ sp: ScreenPaths, verify: Bool) throws -> [CorpusPackage] {
    let candidates = try sp.loadCandidates().packages
    return verify ? Screen.verifyPackages(results: try sp.loadResults(), candidates: candidates) : candidates
}

extension ScreenCommand {
    struct Batch: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Screen one batch of 50 in one fresh guest clone (§5.2).",
            discussion: """
            Builds strict-complete-v5 for the batch, then minimal-v5 only where the complete cell built with at least \
            one primary diagnostic. Resumable: cells already present are skipped, and a batch with every cell present \
            boots no guest. Exits 3 if infra_error cells remain.
            """)

        @OptionGroup var screen: ScreenOptions
        @Argument(help: "Batch number, 1-based.") var batch: Int
        @Flag(name: .long, help: "Re-run the pass-1 emitters into <id>-macos-verify (§5.6).") var verify = false
        @Flag(name: .long, help: "Delete this batch's infra_error cells first so they run again (the one retry).") var retryInfra = false
        @Option(name: .long, help: "Per-cell timeout, minutes.") var timeoutMinutes = 45

        func run() async throws {
            let sp = screen.paths
            let members = Screen.batch(batch, of: try pool(sp, verify: verify))
            guard !members.isEmpty else { throw ValidationError("batch \(batch) is empty") }
            let ids = Set(members.map(\.id))
            // Unresolvable candidates have no vendored graph and are never built (F1); collect records them.
            let buildable = members.filter(sp.hasResolved)
            let paths = sp.corpusPaths
            let runId = verify ? sp.verifyRunId : sp.runId(batch: batch)
            let store = RunStore(root: paths.runDirectory(runId))
            let tc = Screen.toolchain.name

            if retryInfra {
                for cell in try store.loadCells().values where cell.record.outcome == .infraError && ids.contains(cell.record.packageId) {
                    print("retrying \(cell.record.mode.rawValue) \(cell.record.packageId)")
                    try FileManager.default.removeItem(at: cell.directory)
                }
            }

            func pendingMinimal() throws -> [CorpusPackage] {
                let cells = try store.loadCells()
                return buildable.filter { p in
                    guard let c = cells[RunStore.CellKey(toolchain: tc, mode: .strictCompleteV5, packageId: p.id)] else { return false }
                    return Screen.needsMinimal(c) && cells[RunStore.CellKey(toolchain: tc, mode: .minimalV5, packageId: p.id)] == nil
                }
            }

            let completePending = buildable.filter { !store.hasCell(toolchain: tc, mode: .strictCompleteV5, slug: $0.slug) }
            if completePending.isEmpty, try pendingMinimal().isEmpty {
                print("batch \(batch) (\(runId)): every cell present")
            } else {
                // Fetch sources before the guest boots: two cells of one package must not race a clone.
                for p in buildable { try await paths.sources.ensure(p) }
                try FileManager.default.createDirectory(at: paths.scratch, withIntermediateDirectories: true)
                try await withMacGuest(runId: runId, paths: paths, store: store, timeoutMinutes: timeoutMinutes) { runner in
                    await MatrixRun.execute(cells: Screen.cells(buildable, mode: .strictCompleteV5), runner: runner, jobs: 1,
                                            force: false, imageID: { _ in GuestVM.restoreImageDigest() }) { print($0); fflush(stdout) }
                    // Early exit (§5.2 step 4): no primary diagnostic under complete means count 0, no second build.
                    let minimal = try pendingMinimal()
                    await MatrixRun.execute(cells: Screen.cells(minimal, mode: .minimalV5), runner: runner, jobs: 1,
                                            force: false, imageID: { _ in GuestVM.restoreImageDigest() }) { print($0); fflush(stdout) }
                }
            }

            let infra = try store.loadCells().values.filter { $0.record.outcome == .infraError && ids.contains($0.record.packageId) }
            if !infra.isEmpty {
                print("\(infra.count) infra_error cell(s) remain in batch \(batch)")
                throw ExitCode(3)
            }
        }
    }

    struct Batches: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Print how many batches a pass has (for scripts/screen-drive.sh).")
        @OptionGroup var screen: ScreenOptions
        @Flag(name: .long, help: "Count the verify pass (pass-1 emitters) instead of pass 1.") var verify = false

        func run() async throws {
            print(Screen.batchCount(try pool(screen.paths, verify: verify).count))
        }
    }
}
```

- [ ] **Step 3: Build and run the full test suite**

Run: `swift build --package-path tools && swift test --package-path tools`
Expected: build succeeds, all tests pass.

- [ ] **Step 4: Smoke-test with a fixture screen (no network, no guest)**

Run:
```bash
SCR=$(mktemp -d) && mkdir -p "$SCR/fx-2026-10-10"
{ echo "packages:"; for i in $(seq 1 120); do printf -- "- id: o/r%d\n  platforms: [macos-spm]\n  selection: t\n  sha: %040d\n  stratum: screen\n  url: https://github.com/o/r%d\n" $i $i $i; done; echo "schema_version: 1"; } > "$SCR/fx-2026-10-10/candidates.yaml"
tools/.build/debug/census screen batches fx-2026-10-10 --root "$SCR"
tools/.build/debug/census screen batch fx-2026-10-10 9 --root "$SCR"; echo "exit $?"
rm -rf "$SCR"
```
Expected: `batches` prints `3`. `batch … 9` fails with `batch 9 is empty` and a non-zero exit. No guest is cloned.

- [ ] **Step 5: Check that `census run` for macOS is unchanged in behaviour**

Run: `tools/.build/debug/census run --help` and read `Run.run()` once against `git diff`.
Expected: the macOS path still validates the manifest, fetches sources, writes `run.json` once, and destroys the guest on success and on error. Do **not** start a guest.

- [ ] **Step 6: Commit**

```bash
git add tools/Sources/census/Census.swift tools/Sources/census/Screen.swift
git commit -m "census screen batch: one guest per batch, complete then minimal with early exit" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 9: `census screen collect` and `census screen status`

**Files:**
- Modify: `tools/Sources/census/Screen.swift`

**Interfaces:**
- Consumes: Task 7 (`Screen.classify`, `applyVerify`, `denominator`, `emittersCSV`, `date(fromScreenId:)`), Task 8 (`ScreenPaths` members, `ScreenCommand`), `RunComparison.compare`.
- Produces:
  - `census screen collect <id> [--root R] [--with-verify]`. It writes `results.json` (every candidate) and `emitters.csv`, and prints the denominator table. It exits non-zero if any cell is missing, if the table does not sum to the draw, or (with `--with-verify`) if the stable emitters' cells are not A7 set-identical.
  - `census screen status <id> [--root R]`, read-only.

- [ ] **Step 1: Add `Collect` and `Status`**

Change the `subcommands:` list of `ScreenCommand` to `[Batch.self, Batches.self, Collect.self, Status.self]`, then append inside `extension ScreenCommand`:

```swift
    struct Collect: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Merge the batch runs into results.json and emitters.csv, and print the denominator table (§5.5).")

        @OptionGroup var screen: ScreenOptions
        @Flag(name: .long, help: "Apply the verify pass (§5.6): emitters whose re-run differs become unstable.") var withVerify = false

        func run() async throws {
            let sp = screen.paths
            let candidates = try sp.loadCandidates().packages
            guard let asOf = Screen.date(fromScreenId: sp.id) else { throw ValidationError("screen id must end in YYYY-MM-DD") }
            let paths = sp.corpusPaths
            let failures = sp.resolveFailures()
            let tc = Screen.toolchain.name
            func key(_ id: String, _ m: Mode) -> RunStore.CellKey { RunStore.CellKey(toolchain: tc, mode: m, packageId: id) }

            var cells: [RunStore.CellKey: RunStore.LoadedCell] = [:]
            for n in stride(from: 1, through: Screen.batchCount(candidates.count), by: 1) {
                cells.merge(try RunStore(root: paths.runDirectory(sp.runId(batch: n))).loadCells()) { a, _ in a }
            }
            var results = try candidates.enumerated().map { i, p in
                try Screen.classify(package: p, batch: i / Screen.batchSize + 1, resolveFailure: failures[p.id],
                                    complete: cells[key(p.id, .strictCompleteV5)], minimal: cells[key(p.id, .minimalV5)])
            }

            var setIdentical = true
            if withVerify {
                let verifyCells = try RunStore(root: paths.runDirectory(sp.verifyRunId)).loadCells()
                results = try zip(candidates, results).map { p, r in
                    try Screen.applyVerify(r, package: p, complete: verifyCells[key(p.id, .strictCompleteV5)],
                                           minimal: verifyCells[key(p.id, .minimalV5)])
                }
                // A7 over the stable emitters' cells. Unstable ones differ by definition and are excluded above.
                let stable = Set(results.filter { $0.status == .emitter }.map(\.packageId))
                let report = RunComparison.compare(cells.filter { stable.contains($0.key.packageId) },
                                                   verifyCells.filter { stable.contains($0.key.packageId) })
                print("A7 over \(stable.count) stable emitters: \(report.cellsCompared) cells compared, \(report.identical) set-identical")
                for m in report.outcomeMismatches { print("OUTCOME DIFFERS \(m.key): \(m.left.rawValue) vs \(m.right.rawValue)") }
                for d in report.differing { print("MULTISET DIFFERS \(d.key): -\(d.difference.onlyInLeft.count) +\(d.difference.onlyInRight.count)") }
                for k in report.onlyInLeft + report.onlyInRight { print("MISSING IN ONE PASS \(k)") }
                setIdentical = report.isSetIdentical
            }

            let table = try Screen.denominator(drawn: candidates.count, results: results)
            try RunStore(root: sp.directory).write(results, to: sp.results)
            try Screen.emittersCSV(results: results, candidates: candidates, asOf: asOf)
                .write(to: sp.emitters, atomically: true, encoding: .utf8)
            print(table.rendered)
            let minimalFailed = results.filter { $0.status == .minimalFailed }
            if !minimalFailed.isEmpty { print("INVESTIGATE minimal_failed (expected ~0): " + minimalFailed.map(\.packageId).joined(separator: ", ")) }
            if !setIdentical {
                print("NOT SET-IDENTICAL across passes for stable emitters: investigate before selecting (spec §10a rule 6)")
                throw ExitCode.failure
            }
        }
    }

    struct Status: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Read-only: how far the screen has got and what to do next (§10a). Safe at any time.")

        @OptionGroup var screen: ScreenOptions

        func run() async throws {
            let sp = screen.paths
            let fm = FileManager.default
            let launch = "cd \(fm.currentDirectoryPath) && " + (screen.root == "screens" ? "" : "SCREENS_ROOT=\(screen.root) ")
                + "nohup caffeinate -i scripts/screen-drive.sh \(sp.id) >/dev/null 2>&1 &"
            print("screen \(sp.id) at \(sp.directory.path)")
            guard fm.fileExists(atPath: sp.candidates.path) else {
                print("no candidates.yaml\nnext: census select screen --screen-id \(sp.id) --seed 20261004 --count 300; commit it; then launch:\n  \(launch)")
                return
            }
            let candidates = try sp.loadCandidates().packages
            let failures = sp.resolveFailures()
            let resolved = candidates.filter(sp.hasResolved)
            print("candidates \(candidates.count); resolved \(resolved.count); resolve failures \(failures.count); "
                + "not yet resolved \(candidates.count - resolved.count - failures.count)")

            let tc = Screen.toolchain.name
            func progress(_ label: String, pool: [CorpusPackage], runId: (Int) -> String) throws {
                let total = Screen.batchCount(pool.count)
                for n in stride(from: 1, through: total, by: 1) {
                    let members = Screen.batch(n, of: pool).filter(sp.hasResolved)
                    let cells = try RunStore(root: sp.corpusPaths.runDirectory(runId(n))).loadCells()
                    let complete = members.compactMap { cells[RunStore.CellKey(toolchain: tc, mode: .strictCompleteV5, packageId: $0.id)] }
                    let needed = complete.filter(Screen.needsMinimal).count
                    let minimal = members.filter { cells[RunStore.CellKey(toolchain: tc, mode: .minimalV5, packageId: $0.id)] != nil }.count
                    let infra = cells.values.filter { $0.record.outcome == .infraError }.count
                    let marker = fm.fileExists(atPath: sp.state.appendingPathComponent("\(label)-\(n).done").path) ? " [done]" : ""
                    print("  \(label) \(n)/\(total): complete \(complete.count)/\(members.count), minimal \(minimal)/\(needed)"
                        + (infra > 0 ? ", infra_error \(infra)" : "") + marker)
                }
            }
            print("pass 1:")
            try progress("batch", pool: candidates) { sp.runId(batch: $0) }
            if let results = try? sp.loadResults() {
                let byStatus = Dictionary(grouping: results, by: \.status).mapValues(\.count)
                print("results.json: " + ScreenStatus.allCases.map { "\($0.rawValue) \(byStatus[$0] ?? 0)" }.joined(separator: ", "))
                print("verify pass:")
                try progress("verify", pool: Screen.verifyPackages(results: results, candidates: candidates)) { _ in sp.verifyRunId }
            }

            let guests = ((try? await Shell.run("limactl", ["list", "--format", "{{.Name}}"]))?.stdoutString ?? "")
                .split(separator: "\n").map(String.init).filter { $0.hasPrefix("census-run-") }
            print("guest clones: " + (guests.isEmpty ? "none" : guests.joined(separator: ", ") + " (one is expected while a batch runs)"))

            let pidFile = sp.state.appendingPathComponent("driver.pid")
            var driverAlive = false
            if let pid = try? String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
               let ps = try? await Shell.run("ps", ["-p", pid, "-o", "command="]) {
                driverAlive = ps.succeeded && ps.stdoutString.contains("screen-drive.sh")
            }
            print("driver: " + (driverAlive ? "running" : "not running"))
            if let log = try? String(contentsOf: sp.state.appendingPathComponent("drive.log"), encoding: .utf8),
               let last = log.split(separator: "\n").last {
                print("log: \(last)")
            }

            let stopped = try? String(contentsOf: sp.state.appendingPathComponent("STOPPED"), encoding: .utf8)
            let finished = fm.fileExists(atPath: sp.state.appendingPathComponent("collect-verify.done").path)
            if let stopped {
                print("STOPPED: \(stopped.trimmingCharacters(in: .whitespacesAndNewlines))")
                print("next: investigate (never paper over), fix, delete \(sp.state.path)/STOPPED, then relaunch:\n  \(launch)")
            } else if driverAlive {
                print("next: nothing; the driver is running. Re-run this command to check.")
            } else if finished {
                print("next: driver finished. Commit outputs; apply D5 if stable emitters < 45 (runbook step 8); then census select emit --from-screen \(sp.id)")
            } else {
                print("next: the driver is not running and has not finished. Relaunch (resumes; nothing is redone):\n  \(launch)")
            }
        }
    }
```

- [ ] **Step 2: Build and test**

Run: `swift build --package-path tools && swift test --package-path tools`
Expected: build succeeds, all tests pass.

- [ ] **Step 3: Smoke-test collect and status on a fixture with no cells**

Run:
```bash
SCR=$(mktemp -d) && mkdir -p "$SCR/fx-2026-10-10/resolved"
printf 'packages:\n- id: o/a\n  platforms: [macos-spm]\n  selection: t\n  sha: %040d\n  stratum: screen\n  url: https://github.com/o/a\nschema_version: 1\n' 1 > "$SCR/fx-2026-10-10/candidates.yaml"
echo '{"o/a": "o/a: dependency resolution failed"}' > "$SCR/fx-2026-10-10/resolved/failures.json"
tools/.build/debug/census screen collect fx-2026-10-10 --root "$SCR"; echo "exit $?"
cat "$SCR/fx-2026-10-10/results.json" "$SCR/fx-2026-10-10/emitters.csv"
tools/.build/debug/census screen status fx-2026-10-10 --root "$SCR"
rm -f "$SCR/fx-2026-10-10/resolved/failures.json"
tools/.build/debug/census screen collect fx-2026-10-10 --root "$SCR"; echo "exit $?"
rm -rf "$SCR"
```
Expected: the first collect exits 0, the table shows `unresolvable 1` and `sum 1`, `results.json` has one `"status" : "unresolvable"` entry, and `emitters.csv` has only the comment and header. `status` prints the counts, `driver: not running` and a relaunch line with `SCREENS_ROOT=`. The second collect (failure record removed, no cells) fails with `o/a: no strict-complete-v5 cell and no recorded resolve failure`.

- [ ] **Step 4: Commit**

```bash
git add tools/Sources/census/Screen.swift
git commit -m "census screen collect and status" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 10: `census select emit --from-screen`

**Files:**
- Modify: `tools/Sources/CensusRunner/Screen.swift` (add `Selected`, `selectEmit`, `copyResolved`)
- Modify: `tools/Sources/census/Select.swift` (`Emit`)
- Test: `tools/Tests/CensusRunnerTests/ScreenSelectionTests.swift`

**Interfaces:**
- Consumes: `ScreenResult`, `ScreenError` (Task 7); `ResolvedProvenance`; `Selection.sampleAcrossDistribution`; `ScreenPaths` (Tasks 5 and 8).
- Produces:
  - `Screen.Selected { entries: [CorpusPackage]; emitters: Int; perTertile: [Selection.Tertile: Int] }`.
  - `Screen.selectEmit(results:candidates:screenId:seed:count:) throws -> Selected`.
  - `Screen.copyResolved(_ packages: [CorpusPackage], from: URL, to: URL) throws`.
  - CLI: `census select emit --from-screen <id> [--screens-root screens] --seed 20261010 --count 30`.

- [ ] **Step 1: Write the failing tests**

Create `tools/Tests/CensusRunnerTests/ScreenSelectionTests.swift`:

```swift
import CensusCore
import Foundation
import Testing

@testable import CensusRunner

@Suite struct ScreenSelectionTests {
    func cand(_ i: Int) -> CorpusPackage {
        CorpusPackage(id: "o/r\(i)", url: "https://github.com/o/r\(i)", sha: String(format: "%040x", i),
                      stratum: .screen, platforms: [.macosSPM], selection: "t")
    }
    func emitter(_ i: Int, count: Int, status: ScreenStatus = .emitter) -> ScreenResult {
        ScreenResult(packageId: "o/r\(i)", sha: String(format: "%040x", i), status: status, screenCount: count, batch: 1,
                     verifyScreenCount: count)
    }

    /// G1: the screened SHA is the measurement. It is kept, never re-resolved.
    @Test func keepsTheScreenedSHAAndRecordsTheScreen() throws {
        let cands = (1...60).map(cand)
        let s = try Screen.selectEmit(results: (1...60).map { emitter($0, count: $0) }, candidates: cands,
                                      screenId: "screen-2026-10-10", seed: 20261010, count: 30)
        #expect(s.entries.count == 30 && s.emitters == 60)
        #expect(s.perTertile[.head] == 10 && s.perTertile[.middle] == 10 && s.perTertile[.tail] == 10)
        for e in s.entries {
            let c = try #require(cands.first { $0.id == e.id })
            #expect(e.sha == c.sha && e.url == c.url && e.stratum == .emit && e.platforms == [.linuxSPM, .macosSPM])
            #expect(e.screenId == "screen-2026-10-10" && e.screenCountAtSelection != nil)
            #expect(e.spiErrorCountAtSelection == nil)
            #expect(e.selection.contains("seed=20261010") && e.selection.contains("screen-2026-10-10"))
        }
    }

    @Test func neverSelectsUnstableOrNonEmitters() throws {
        let rs = [emitter(1, count: 5), emitter(2, count: 9, status: .unstable),
                  ScreenResult(packageId: "o/r3", sha: "", status: .clean, screenCount: 0, batch: 1),
                  ScreenResult(packageId: "o/r4", sha: "", status: .notScreenable, reason: "build_failed", batch: 1)]
        let s = try Screen.selectEmit(results: rs, candidates: (1...4).map(cand), screenId: "x", seed: 1, count: 30)
        #expect(s.entries.map(\.id) == ["o/r1"] && s.emitters == 1)
    }

    @Test func refusesEmittersThatWereNeverVerified() {
        var r = emitter(1, count: 5)
        r.verifyScreenCount = nil
        #expect(throws: ScreenError.self) {
            try Screen.selectEmit(results: [r], candidates: [cand(1)], screenId: "x", seed: 1, count: 30)
        }
    }

    func tempDirs() throws -> (URL, URL) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("sel-\(UUID())")
        let src = base.appendingPathComponent("src"), dst = base.appendingPathComponent("dst")
        for d in [src, dst] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        let prov = ["o/r1": ResolvedProvenance(source: "generated", toolchain: "6.4", resolvedAt: "2026-10-10T00:00:00Z", sha256: "s", pinCount: 2)]
        try RunStore(root: src).write(prov, to: src.appendingPathComponent("provenance.json"))
        try Data("{\n  \"pins\" : [ ],\n  \"version\" : 3\n}\n".utf8).write(to: src.appendingPathComponent("o__r1.resolved"))
        let existing = ["other/x": ResolvedProvenance(source: "upstream", toolchain: "6.4", resolvedAt: "x", sha256: "t", pinCount: 0)]
        try RunStore(root: dst).write(existing, to: dst.appendingPathComponent("provenance.json"))
        return (src, dst)
    }

    @Test func copiesResolvedBytesUnchangedAndMergesProvenance() throws {
        let (src, dst) = try tempDirs()
        try Screen.copyResolved([cand(1)], from: src, to: dst)
        #expect(try MatrixRun.sha256Hex(of: src.appendingPathComponent("o__r1.resolved"))
            == MatrixRun.sha256Hex(of: dst.appendingPathComponent("o__r1.resolved")))
        let prov = try JSONDecoder().decode([String: ResolvedProvenance].self, from: Data(contentsOf: dst.appendingPathComponent("provenance.json")))
        #expect(prov.keys.sorted() == ["o/r1", "other/x"])
        #expect(prov["o/r1"]?.source == "generated")
    }

    @Test func refusesToOverwriteADifferentPinnedFileAndWritesNothing() throws {
        let (src, dst) = try tempDirs()
        let target = dst.appendingPathComponent("o__r1.resolved")
        try Data("different".utf8).write(to: target)
        #expect(throws: ScreenError.self) { try Screen.copyResolved([cand(1)], from: src, to: dst) }
        #expect(try String(contentsOf: target, encoding: .utf8) == "different")
        let prov = try JSONDecoder().decode([String: ResolvedProvenance].self, from: Data(contentsOf: dst.appendingPathComponent("provenance.json")))
        #expect(prov.keys.sorted() == ["other/x"])
    }
}
```

- [ ] **Step 2: Run the tests and watch them fail**

Run: `swift test --package-path tools --filter ScreenSelectionTests`
Expected: compile error, `type 'Screen' has no member 'selectEmit'`.

- [ ] **Step 3: Implement**

Append inside `public enum Screen` in `tools/Sources/CensusRunner/Screen.swift`:

```swift
    public struct Selected: Sendable {
        public var entries: [CorpusPackage]
        public var emitters: Int
        public var perTertile: [Selection.Tertile: Int]
    }

    /// §5.7. Tertiles over the stable emitters, at each candidate's screened SHA (G1). Fewer than `count`, or an
    /// empty tertile, yields what exists: never padded. Refuses emitters that were never verified (§5.6).
    public static func selectEmit(results: [ScreenResult], candidates: [CorpusPackage], screenId: String,
                                  seed: UInt64, count: Int) throws -> Selected {
        let emitters = results.filter { $0.status == .emitter }
        if let unverified = emitters.first(where: { $0.verifyScreenCount == nil }) {
            throw ScreenError.unverified(unverified.packageId)
        }
        let byId = Dictionary(candidates.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        // `SPIRow` is named for SPI's export; here `errors` carries the screen count. Renaming it is out of scope.
        let rows = emitters.compactMap { r -> SPIRow? in
            guard let p = byId[r.packageId], let n = r.screenCount else { return nil }
            return SPIRow(url: p.url, errors: n, swiftVersion: swiftVersionLabel, asOf: "")
        }
        let byURL = Dictionary(candidates.map { ($0.url, $0) }, uniquingKeysWith: { a, _ in a })
        var perTertile: [Selection.Tertile: Int] = [:]
        var entries: [CorpusPackage] = []
        for (row, tertile) in Selection.sampleAcrossDistribution(rows: rows, count: count, seed: seed) {
            guard let c = byURL[row.url] else { continue }
            perTertile[tertile, default: 0] += 1
            entries.append(CorpusPackage(
                id: c.id, url: c.url, sha: c.sha, stratum: .emit, platforms: [.linuxSPM, .macosSPM],
                selection: "seed=\(seed) \(tertile.rawValue)-tertile of \(rows.count) stable emitters; "
                    + "screen \(screenId) count \(row.errors); screened SHA (ADR 0007)",
                screenId: screenId, screenCountAtSelection: row.errors))
        }
        return Selected(entries: entries, emitters: rows.count, perTertile: perTertile)
    }

    /// §5.7 and G1: the matrix must build the graph that was screened, so each vendored file is copied byte for byte
    /// and never re-resolved. Checks everything before writing anything, and refuses to replace a different
    /// existing file: a pinned graph is never changed as a drive-by.
    public static func copyResolved(_ packages: [CorpusPackage], from source: URL, to destination: URL) throws {
        let decoder = JSONDecoder()
        let sourceProvenance = try decoder.decode([String: ResolvedProvenance].self,
                                                  from: Data(contentsOf: source.appendingPathComponent("provenance.json")))
        let destinationProvenanceURL = destination.appendingPathComponent("provenance.json")
        var destinationProvenance: [String: ResolvedProvenance] = [:]
        if FileManager.default.fileExists(atPath: destinationProvenanceURL.path) {
            destinationProvenance = try decoder.decode([String: ResolvedProvenance].self, from: Data(contentsOf: destinationProvenanceURL))
        }
        var writes: [(URL, Data)] = []
        for p in packages {
            let name = "\(p.slug).resolved"
            let bytes = try Data(contentsOf: source.appendingPathComponent(name))
            let target = destination.appendingPathComponent(name)
            if let existing = try? Data(contentsOf: target), existing != bytes { throw ScreenError.resolvedMismatch(p.id) }
            guard let provenance = sourceProvenance[p.id] else { throw ScreenError.incomplete(p.id, "no provenance entry in \(source.path)") }
            writes.append((target, bytes))
            destinationProvenance[p.id] = provenance
        }
        for (url, bytes) in writes { try bytes.write(to: url) }
        try RunStore(root: destination).write(destinationProvenance, to: destinationProvenanceURL)
    }
```

In `tools/Sources/census/Select.swift`, give `Emit` two new options and an early branch. Update its `abstract` to mention the screen:

```swift
        @Option(name: .long, help: "Select from a collected screen (ADR 0007) instead of an SPI export.") var fromScreen: String?
        @Option(name: .long, help: "Directory holding screen directories.") var screensRoot = "screens"
```

At the top of `Emit.run()`, before `let rows = …`:

```swift
            if let id = fromScreen {
                let sp = ScreenPaths(root: screensRoot, id: id)
                let selected = try Screen.selectEmit(results: try sp.loadResults(), candidates: try sp.loadCandidates().packages,
                                                     screenId: id, seed: seed, count: count)
                print("stable emitters \(selected.emitters); selected \(selected.entries.count) of \(count): "
                    + [Selection.Tertile.head, .middle, .tail].map { "\($0.rawValue) \(selected.perTertile[$0] ?? 0)" }.joined(separator: ", "))
                if selected.entries.count < count {
                    print("FEWER THAN \(count): taking what exists, not padding. Record this in ADR 0007's results.")
                }
                // Copy first: if it refuses, the manifest is untouched.
                try Screen.copyResolved(selected.entries, from: sp.resolved, to: paths.resolved)
                try save(manifest, to: paths.corpus, replacing: .emit, with: selected.entries)
                return
            }
```

- [ ] **Step 4: Run all tests**

Run: `swift test --package-path tools`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add tools/Sources/CensusRunner/Screen.swift tools/Sources/census/Select.swift tools/Tests/CensusRunnerTests/ScreenSelectionTests.swift
git commit -m "select emit --from-screen: tertiles at the screened SHA, resolved bytes copied unchanged" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 11: `scripts/screen-drive.sh` — the unattended, resumable driver

**Files:**
- Create: `scripts/screen-drive.sh` (executable)

**Interfaces:**
- Consumes: `census resolve --manifest --resolved --toolchain --allow-failures` (Task 6); `census screen batches|batch|collect` with their exit codes (Tasks 8 and 9).
- Produces: state under `work/screen-state/<id>/`: `drive.log`, `driver.pid`, `STOPPED`, and `*.done` markers (`resolve`, `batch-N`, `collect`, `verify-N`, `collect-verify`) plus `*.retried`.

- [ ] **Step 1: Write the script**

Create `scripts/screen-drive.sh`:

```bash
#!/usr/bin/env bash
# scripts/screen-drive.sh: the unattended driver for the S-emit screen (ADR 0007; spec §10a).
#
# Launch from Terminal.app so it outlives Claude Code:
#   cd /Users/aj/iOS/SwiftCensus
#   nohup caffeinate -i scripts/screen-drive.sh screen-2026-10-10 >/dev/null 2>&1 &
#
# `caffeinate -i` prevents idle sleep only. It does NOT keep a laptop awake with the lid closed on battery: keep the
# machine plugged in with the lid open (or in clamshell mode with a display).
#
# Phases: resolve (Docker on) -> quit Docker -> pass-1 batches -> collect -> verify batches -> collect --with-verify
# -> start Docker. It stops there: the extension (D5) and selection are separate, manual steps. After a D5 extension,
# delete work/screen-state/<id>/*.done and relaunch; that is safe because every phase skips finished work.
#
# Idempotent: rerun after any interruption (crash, sleep, SIGKILL, session end). The on-disk cells are the truth, and
# the *.done files are only an optimisation. It never commits, and never edits tracked files except through `census`.
# On a state it does not understand it writes STOPPED with the reason and exits non-zero. It never papers over.
#
# Environment: SCREENS_ROOT (default "screens", used by the dry run); CENSUS to use a prebuilt binary.
set -euo pipefail

ID="${1:?usage: screen-drive.sh <screen-id>}"
cd "$(dirname "$0")/.."
ROOT="${SCREENS_ROOT:-screens}"
STATE="work/screen-state/$ID"
LOG="$STATE/drive.log"
mkdir -p "$STATE"

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$LOG"; }
stop() { printf '%s\n' "$*" > "$STATE/STOPPED"; log "STOPPED: $*"; exit 1; }
is_done() { [[ -f "$STATE/$1.done" ]]; }
mark_done() { touch "$STATE/$1.done"; }

if [[ -f "$STATE/STOPPED" ]]; then
  log "refusing to start: STOPPED exists ($(cat "$STATE/STOPPED")); investigate, fix, delete it, relaunch"
  exit 1
fi

# One driver at a time. A pid file left by a SIGKILLed driver is ignored once that pid is not a driver.
if [[ -f "$STATE/driver.pid" ]]; then
  old=$(cat "$STATE/driver.pid")
  if ps -p "$old" -o command= 2>/dev/null | grep -q 'screen-drive.sh'; then
    log "another driver is running (pid $old); exiting"
    exit 1
  fi
fi
echo $$ > "$STATE/driver.pid"
trap 'rm -f "$STATE/driver.pid"' EXIT

# A SIGKILLed driver leaves its child `census` running. It would race this driver for the guest and the cells.
reap() {
  if pkill -KILL -f "census (screen|resolve) .*$ID" 2>/dev/null; then log "killed an orphaned census process from a previous driver"; fi
  sleep 2
  local inst
  for inst in $(limactl list --format '{{.Name}}' 2>/dev/null | grep '^census-run-' || true); do
    log "deleting stale guest clone $inst"
    limactl stop "$inst" >/dev/null 2>&1 || true
    limactl delete --force "$inst" >>"$LOG" 2>&1 || true
  done
}

docker_up() {
  docker info >/dev/null 2>&1 && return 0
  log "starting Docker Desktop"
  open -a Docker
  local _
  for _ in $(seq 1 100); do docker info >/dev/null 2>&1 && return 0; sleep 3; done
  stop "Docker did not come up within 300 s"
}

# Docker's VM (7.75 GiB) and the macOS guest (10 GiB) cannot coexist in 16 GiB (spec §0, G2).
docker_down() {
  pgrep -f 'Docker.app/Contents' >/dev/null 2>&1 || return 0
  log "quitting Docker Desktop before the macOS phase"
  osascript -e 'quit app "Docker Desktop"' >/dev/null 2>&1 || true
  local _
  for _ in $(seq 1 60); do pgrep -f 'Docker.app/Contents' >/dev/null 2>&1 || return 0; sleep 2; done
  stop "Docker Desktop did not quit within 120 s; the guest cannot run beside it"
}

check_disk() {
  local free
  free=$(df -g . | awk 'NR==2 {print $4}')
  (( free >= 25 )) || stop "only ${free} GB free; each guest clone grows the sparse image (spec §0)"
}

CENSUS="${CENSUS:-}"
if [[ -z "$CENSUS" ]]; then
  log "building census"
  swift build -c release --package-path tools >>"$LOG" 2>&1 || stop "swift build failed; see $LOG"
  CENSUS="tools/.build/release/census"
fi
run_census() { "$CENSUS" "$@" >>"$LOG" 2>&1; }

# $1: "" for pass 1 or "--verify"; $2: marker prefix ("batch" or "verify").
batch_loop() {
  local flag="$1" prefix="$2" total n rc
  # shellcheck disable=SC2086
  total=$("$CENSUS" screen batches "$ID" --root "$ROOT" $flag 2>>"$LOG") || stop "cannot count $prefix batches; see $LOG"
  for (( n = 1; n <= total; n++ )); do
    is_done "$prefix-$n" && continue
    check_disk
    log "phase: $prefix $n/$total"
    set +e
    # shellcheck disable=SC2086
    run_census screen batch "$ID" "$n" --root "$ROOT" $flag
    rc=$?
    if (( rc == 3 )) && [[ ! -f "$STATE/$prefix-$n.retried" ]]; then
      touch "$STATE/$prefix-$n.retried"
      log "infra_error cells in $prefix $n; retrying them once"
      # shellcheck disable=SC2086
      run_census screen batch "$ID" "$n" --root "$ROOT" $flag --retry-infra
      rc=$?
    fi
    set -e
    (( rc == 0 )) || stop "$prefix $n exited $rc (3 = infra_error after one retry); see $LOG"
    mark_done "$prefix-$n"
  done
}

log "driver start (pid $$) for $ROOT/$ID"
reap
[[ -f "$ROOT/$ID/candidates.yaml" ]] || stop "no $ROOT/$ID/candidates.yaml; draw first (census select screen)"

if ! is_done resolve; then
  docker_up
  stale=$(docker ps -aq --filter name=census-resolve- 2>/dev/null || true)
  # shellcheck disable=SC2086
  [[ -z "$stale" ]] || docker rm -f $stale >/dev/null 2>&1 || true
  log "phase: resolve"
  run_census resolve --manifest "$ROOT/$ID/candidates.yaml" --resolved "$ROOT/$ID/resolved" --toolchain 6.4 --allow-failures \
    || stop "census resolve failed outright; see $LOG"
  mark_done resolve
fi

docker_down
batch_loop "" batch

if ! is_done collect; then
  log "phase: collect"
  run_census screen collect "$ID" --root "$ROOT" || stop "collect failed (missing cells or a denominator mismatch); see $LOG"
  mark_done collect
fi

batch_loop "--verify" verify

if ! is_done collect-verify; then
  log "phase: collect --with-verify"
  run_census screen collect "$ID" --root "$ROOT" --with-verify \
    || stop "collect --with-verify failed (missing verify cells, or stable emitters not set-identical); see $LOG"
  mark_done collect-verify
fi

docker_up
log "finished: commit the outputs, then apply D5 if needed (runbook step 8) and select (step 9)"
```

Run: `chmod +x scripts/screen-drive.sh`

- [ ] **Step 2: Check the syntax, and lint if shellcheck is present**

Run: `bash -n scripts/screen-drive.sh && (command -v shellcheck >/dev/null && shellcheck scripts/screen-drive.sh || echo "shellcheck not installed; skipped")`
Expected: no syntax errors and no shellcheck warnings beyond the disabled SC2086 lines.

- [ ] **Step 3: Exercise the guard paths without Docker or a guest**

Run:
```bash
SCREENS_ROOT=work/nonexistent-root CENSUS=tools/.build/debug/census scripts/screen-drive.sh guardtest-2026-10-10; echo "exit $?"
cat work/screen-state/guardtest-2026-10-10/STOPPED
SCREENS_ROOT=work/nonexistent-root CENSUS=tools/.build/debug/census scripts/screen-drive.sh guardtest-2026-10-10; echo "exit $?"
tail -1 work/screen-state/guardtest-2026-10-10/drive.log
rm -rf work/screen-state/guardtest-2026-10-10
```
Expected: the first run exits 1 with `STOPPED` reading `no work/nonexistent-root/guardtest-2026-10-10/candidates.yaml; draw first …`. The second run exits 1 without doing anything, and the log's last line says it refuses to start because STOPPED exists. Neither run touches Docker or Lima, apart from the read-only `limactl list` in `reap`.

- [ ] **Step 4: Commit**

```bash
git add scripts/screen-drive.sh
git commit -m "scripts/screen-drive.sh: unattended, resumable screen driver" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 12: Dry run on 5 candidates, including a SIGKILL mid-batch (operational: the controller runs it, not a subagent)

The 5 candidates are the first 5 of the real draw. Everything goes under scratch paths and is deleted at the end. **Do not skip this:** three of this project's worst bugs were found by a first real run.

- [ ] **Step 1: Preconditions**

Run: `git status --porcelain && limactl list && df -g . | awk 'NR==2{print $4" GB free"}'`
Expected: a clean tree; `census-macos` is `Stopped`; no `census-run-*`; at least 25 GB free.

- [ ] **Step 2: Draw 5 into a scratch root**

Run: `swift build --package-path tools -c release && tools/.build/release/census select screen --screen-id dryrun-2026-10-10 --root work/dryrun-screens --seed 20261004 --count 5`
Expected: `drew 5 of 5 from position 0`. Run it a second time without `--extend`: it must refuse with "exists and is pinned".

- [ ] **Step 3: Launch the driver in the background**

Run (Bash with `run_in_background: true`): `SCREENS_ROOT=work/dryrun-screens CENSUS=tools/.build/release/census caffeinate -i scripts/screen-drive.sh dryrun-2026-10-10`

Then check every few minutes with `tools/.build/release/census screen status dryrun-2026-10-10 --root work/dryrun-screens` and `tail -3 work/screen-state/dryrun-2026-10-10/drive.log`. Use the Monitor tool with an until-loop, not foreground sleeps.

- [ ] **Step 4: SIGKILL the driver mid-batch**

When status shows `batch 1/1: complete k/…` with `k ≥ 2`:

```bash
find runs/dryrun-2026-10-10-macos-b1 -name cell.json -exec shasum -a 256 {} + > work/dryrun-before.sha
kill -9 "$(cat work/screen-state/dryrun-2026-10-10/driver.pid)"
pgrep -fl "census screen batch dryrun" || echo "no orphan"
```
Expected: an orphaned `census screen batch` is still running. That shows why `reap` exists.

- [ ] **Step 5: Relaunch and let it finish**

Relaunch with the exact command from Step 3. Wait until `status` prints `driver finished`.

- [ ] **Step 6: Verify resumability and correctness**

Run:
```bash
shasum -a 256 -c work/dryrun-before.sha
limactl list | grep census-run- || echo "no stale guests"
pgrep -fl "census screen" || echo "no census processes"
grep -E "killed an orphaned|deleting stale guest" work/screen-state/dryrun-2026-10-10/drive.log
tools/.build/release/census screen collect dryrun-2026-10-10 --root work/dryrun-screens --with-verify
python3 -c "import json;print(len(json.load(open('work/dryrun-screens/dryrun-2026-10-10/results.json'))))"
```
Expected:
- Every pre-kill `cell.json` reports `OK`, so no completed cell ran twice.
- No stale guests and no census processes remain.
- The log shows the reaper acted.
- The table's `sum` is 5 and `results.json` has 5 entries.
- Docker Desktop is running again.

If any check fails, stop and debug (superpowers:systematic-debugging) before Task 13.

- [ ] **Step 7: Note anything surprising, then delete the scratch artefacts**

Before deleting, write down the denominator table, per-cell durations, any `not_screenable` reasons, and anything unexpected. These go in the final report, not in a committed file. Then:

```bash
rm -rf work/dryrun-screens work/screen-state/dryrun-2026-10-10 work/dryrun-before.sha runs/dryrun-2026-10-10-macos-b1 runs/dryrun-2026-10-10-macos-verify
git status --porcelain
```
Expected: `git status` is clean.

---

### Task 13: The screen (operational: controller and owner)

- [ ] **Step 1: Draw 300 and commit them**

Run: `tools/.build/release/census select screen --screen-id screen-2026-10-10 --seed 20261004 --count 300`
Check:
```bash
grep -c "^- id:" screens/screen-2026-10-10/candidates.yaml
comm -12 <(awk '/^- id:/{print $3}' corpus/packages.yaml | sort) <(awk '/^- id:/{print $3}' screens/screen-2026-10-10/candidates.yaml | sort)
```
Expected: `300`, then no output (disjoint from the corpus).

```bash
git add screens/screen-2026-10-10/candidates.yaml
git commit -m "Screen: draw 300 candidates (ADR 0007, seed 20261004)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```
Confirm that ADR 0007's commit precedes this one: `git log --oneline -- docs/decisions/0007-s-emit-by-macos-screen.md screens/`.

- [ ] **Step 2: Launch the driver**

Ask the owner to run this from Terminal.app (most robust):
```
cd /Users/aj/iOS/SwiftCensus
nohup caffeinate -i scripts/screen-drive.sh screen-2026-10-10 >/dev/null 2>&1 &
```
Machine plugged in, lid open. Expected wall time: ~2.5 h resolve + ~7–10 h screen + ~1.5 h verify.

- [ ] **Step 3: Monitor and commit as phases finish**

Poll `tools/.build/release/census screen status screen-2026-10-10` on a long interval (≥20 min). After each finished phase, commit its outputs:
- after resolve: `screens/screen-2026-10-10/resolved/`
- after each batch: `runs/screen-2026-10-10-macos-bN/`
- after collect: `results.json`, `emitters.csv`
- after the verify pass: `runs/screen-2026-10-10-macos-verify/` and the re-collected `results.json`

Commit message pattern: `Screen: <phase> (<N> cells)`. Never commit while the driver is writing that same directory.

If `STOPPED` appears, read it and investigate. Never relax an assertion. Fix, delete `STOPPED`, relaunch.

- [ ] **Step 4: Apply D5 if needed**

Count the stable emitters: `grep -c '"status" : "emitter"' screens/screen-2026-10-10/results.json`. If fewer than **45**:

```bash
tools/.build/release/census select screen --screen-id screen-2026-10-10 --seed 20261004 --count 150 --extend
git add screens/screen-2026-10-10/candidates.yaml && git commit -m "Screen: D5 extension, +150 candidates" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
rm -f work/screen-state/screen-2026-10-10/*.done
```
Then relaunch the driver as in Step 2 and repeat Step 3. Do this **once only**.

---

### Task 14: Select, validate, record results, report (operational: controller)

- [ ] **Step 1: Select**

Run:
```bash
tools/.build/release/census select emit --from-screen screen-2026-10-10 --seed 20261010 --count 30
tools/.build/release/census validate
swift test --package-path tools
```
Expected: per-tertile counts are printed, `validate` exits 0 with `S-emit=30` (or fewer, as stated), and all tests pass.

- [ ] **Step 2: Verify the acceptance criteria mechanically**

```bash
# Each S-emit entry's .resolved is byte-identical to the screened one. Keys are sorted, so `id` precedes `screen_id`.
awk '/^- id:/{id=$3} /^  screen_id: screen-2026-10-10/{gsub("/","__",id); print id}' corpus/packages.yaml \
  | tee /dev/stderr | while read -r slug; do
      cmp -s "screens/screen-2026-10-10/resolved/$slug.resolved" "corpus/resolved/$slug.resolved" || echo "MISMATCH $slug"
    done
git log --oneline --reverse -- docs/decisions/0007-s-emit-by-macos-screen.md screens/ | head -3
# 04de590 is HEAD when this plan was written: no pre-existing run directory may differ from it.
git diff --stat 04de590 HEAD -- runs/2026-10-04 runs/2026-10-04-rerun runs/2026-10-10-macos runs/2026-10-10-macos-rerun
```
Expected: the selected slugs are listed with no `MISMATCH`. The oldest commit listed is ADR 0007's. The `git diff --stat` output is empty.

- [ ] **Step 3: Commit the corpus**

```bash
git add corpus/packages.yaml corpus/resolved/
git commit -m "S-emit: 30 entries selected from screen-2026-10-10 (ADR 0007)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

- [ ] **Step 4: Fill ADR 0007's Results, and update the READMEs**

In ADR 0007, edit only the "Results" section. Record: N drawn (and whether D5 applied), the denominator table verbatim, the emit rate with its denominator (`emitter / drawn`, and `emitter / (drawn − unresolvable − not_screenable)` labelled as such), counts per tertile, every `unstable` and `minimal_failed` with its reason, and what was **not** verified. No interpretation beyond the numbers.

`runs/README.md`: list the `screen-2026-10-10-macos-b*` and `-verify` runs with cell counts and the A7 line from `collect --with-verify`.

`corpus/README.md`: document `S-emit`'s provenance (ADR 0007) and the `select emit --from-screen` command, and note that `spi-counts.csv` is now a validation join only (§8).

```bash
git add docs/decisions/0007-s-emit-by-macos-screen.md runs/README.md corpus/README.md
git commit -m "ADR 0007 results; document the screen in runs/ and corpus/ READMEs" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

Make sure Docker Desktop is running.

- [ ] **Step 5: Report and hand back**

Report to the owner, plainly:
- the denominator table
- the emit rate, with its denominator
- counts per tertile
- instabilities
- what was excluded and why
- anything unexpected, including dry-run observations
- what was **not** verified

**Stop here.** The `S-emit` matrix runs (Linux toolchains, macOS pair) and evaluating G2 are the next task (spec §12).
