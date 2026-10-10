# Spec — the macOS screen for `S-emit`

**Status:** draft for owner review, then hand-off to an implementing agent.
**Branch:** continue on `m1/matrix-runner`.
**Implements:** ADR 0004 §4's fallback ("option 4"), on the macOS platform of ADR 0006.
**Does not implement:** the full `S-emit` matrix runs, M2, or anything in SPEC §9.4.

---

## 0. Read this first

You are building the instrument that selects the `S-emit` stratum by measurement, because SPI's
per-package counts cannot be fetched (Cloudflare challenge; the owner chose not to defeat it and has not
supplied an export). Read, in order: `CLAUDE.md`, `docs/decisions/0001`–`0006`, `runs/README.md`,
`corpus/README.md`. The rules in `CLAUDE.md` bind you; the ones that bite here:

- `expect`-style assertions are never relaxed to get green. A mismatch is investigated.
- **Corpus SHAs and vendored `Package.resolved` files are pinned deliberately.** Never bump one as a drive-by.
- **Prefer deleting scope to deferring it.** If a thing in this spec is not needed to select `S-emit`, cut it.
- **P1: measure, don't curate.** No hand-picking candidates, no excluding a package "because it looks odd".
- **No unreviewed generated prose** in `entries/*/NOTES.md` (not relevant yet; do not create `entries/`).
- Do **not** try to fetch anything from swiftpackageindex.com. It is behind a bot challenge and `robots.txt`
  disallows `/api/`. Do not defeat it.

### Facts about this machine you cannot infer

- macOS 27.0 host, Apple silicon, **16 GiB RAM**. Docker Desktop's VM (7.75 GiB) and the macOS guest
  (10 GiB) **cannot run together**: the host swaps and guest first-boots stall. **Quit Docker Desktop
  before any macOS run** (`osascript -e 'quit app "Docker Desktop"'`); relaunch it after.
- The macOS guest is the Lima instance `census-macos` (stopped; it is the golden image — never start it
  for a run, and never leave it modified). `census run --platform macos` clones it per run and deletes the
  clone. It has a verified egress firewall (`tools/vm/pf.census.conf`). See ADR 0006.
- `limactl snapshot` does not work for macOS guests; `limactl clone` does.
- The machine slept once mid-run and produced a nonsense 6,635 s duration. Wrap long runs in `caffeinate -i`.
- Free disk was ~87 GB. The guest is 100 GiB sparse; each run's clone adds to it. Watch it.

---

## 1. What the screen is, and why its design is not obvious

`S-emit` exists to put enough emitting packages in the census that the distribution is not near-empty
(ROADMAP A3). SPI's count was meant to be the *sampling frame*, "not a result". The screen replaces that
frame with our own measurement:

1. Draw candidates from the public SPI PackageList, seeded.
2. Build each on macOS under the census's canonical mode and **count what strict concurrency checking adds**.
3. Define `S-emit` as a tertile sample (head / middle / tail) of the candidates with a count above zero.

The consequence you must keep in mind throughout: **the screen measures the same thing the census later
reports.** On the screened toolchain and platform, an `S-emit` package's matrix count *equals* its screen
count, by construction (same source, same `Package.resolved`, same compiler, deterministic per A7). So:

- `S-emit` frequencies are conditioned on "emits > 0" and are **not an ecosystem estimate**. They are reported
  separately from `S-control`, always.
- ROADMAP gate **G2** ("did `S-emit` actually emit?") is **tautological on the screening column** and must be
  redefined before any data is seen. See §6, decision D8.
- Because the screen touches ~300 uniformly drawn packages, it yields a second product worth keeping: the
  **emit rate in a uniform sample**, with a denominator. Commit every candidate's outcome, not just emitters.

---

## 2. Decisions to confirm (owner) — with the defaults you implement unless told otherwise

Each is a place where the project's docs are silent or ambiguous. **Do not decide these silently.** If the
owner has not overridden a default when you start, implement the default and record it in ADR 0007 (§4.1).

| # | Question | Default (my recommendation) | Why |
|---|---|---|---|
| D1 | What is "the count"? | **Differential:** diagnostics in the `complete` build that are absent from a `minimal` build of the same source (§5.3) | Needs no list of "concurrency diagnostics" (a judgement call, and M2's job). In run data `sema_no_import` and `expression_unused_result_call` appear among primary warnings/errors, so a raw count would call unrelated noise "concurrency" |
| D2 | Which frame? | **Same PackageList commit as `S-control`** (`4dc1035a98457e87f4d2c5649a33cd43ee6b80e8`) | Keeps the two strata comparable. The list has moved since; do not refresh it |
| D3 | How to draw? | **Continue the existing seeded order** (seed `20261004`), skipping everything already in `corpus/packages.yaml`, taking the next **300** eligible | Disjoint from `S-control` by construction, no new RNG choice to pre-register, one frame |
| D4 | How many candidates? | **300**, fixed in advance, no stopping early | Run data: on macOS ~28% of drawn candidates were built emitters; the differential will lower that. 300 leaves headroom for 30. Stopping when "enough" emit is optional stopping and biases the emit rate |
| D5 | What if emitters < 45 after the 300? | **One** pre-registered extension of +150 in the same order, then proceed with whatever exists | 45 = at least 15 per tertile. One extension, not a loop |
| D6 | Candidates that do not build on macOS? | **Recorded as `not_screenable` and excluded from `S-emit`**, but kept in the denominator | iOS-only packages (UIKit etc.) cannot build under `swift build` on macOS. SPI builds them with `xcodebuild`; we do not (A11 scope). **This is a known bias** (§9); state it, do not fix it |
| D7 | Where does the screen's count come from when it differs by toolchain? | **One toolchain: Xcode 27.0, `strict-complete-v5`**. Packages that emit only on Linux or only on nightly are missed | A12: macOS canonical; single toolchain |
| D8 | Redefine G2? | **Yes, in ADR 0007, before the screen runs:** G2 becomes "among the 30 `S-emit` packages, what fraction emit ≥1 primary diagnostic **on the Linux 6.4 column** (a different platform, so not tautological), and what fraction on nightly?" Failing threshold: below 50% → investigate the selector before M2 | The original wording cannot fail. This keeps G2 a real check on the selector |
| D9 | Re-run (A7) for the screen? | **Re-run the emitters only** (§5.6), not all 300 | Tertile cuts depend on every emitter's count, so stability of the emitters is what matters. A non-emitter flipping to emitter is a risk we state, not close |
| D10 | Commit raw output for all ~600 screen cells? | **Yes** (`CLAUDE.md`: commit raw bytes). Estimated ~45 MB. | Owner should veto if repo size matters; otherwise this is the rule |
| D11 | Sample size and rule | **30**, tertiles over emitters ordered by count descending, seed `20261010`, via the existing `Selection.sampleAcrossDistribution` | ROADMAP target is ~30. The function is already implemented and tested |
| D12 | New `Stratum` case for candidates? | **Yes: `Stratum.screen = "screen"`** | Reusing `S-emit` for non-members is a lie that survives into `census validate`; the case is a few lines |

If D1 is overridden to a raw count, say so in ADR 0007 and note the noise it admits; do not quietly use it.

---

## 3. Pre-registration

The following are fixed **before the first screening build** and written into ADR 0007 (§4.1), committed
**before** the screen runs. They may not change after results are seen. If one turns out to be wrong,
write a new ADR saying so and re-run; do not edit the old one.

- frame, seed, candidate count, extension rule, eligibility filters (§5.1)
- the count definition and the `built` requirement (§5.3)
- the sampling rule and seed (D11)
- the redefined G2 (D8)
- the stability rule (§5.6)

---

## 4. Deliverables

### 4.1 `docs/decisions/0007-s-emit-by-macos-screen.md`

Amends A3 and ADR 0004 §4. Status "accepted" once the owner confirms §2. Contents: the pre-registration
list above; the "why not tautological" statement for G2; the known biases (§9); the relationship to SPI
data (§8); and a results section **left empty until the screen has run**, then filled in factually
(emit rate, N, counts per tertile, instability). No interpretation beyond what the numbers support.

### 4.2 Code (Swift, in `tools/`; follow the surrounding style)

| Change | Where | Notes |
|---|---|---|
| `Mode.minimalV5 = "minimal-v5"` | `CensusCore/CellRecord.swift` | `-strict-concurrency=minimal` with `-swift-version 5` forced; every other flag as `strict-complete-v5`. Extend `BuildInvocation.swiftBuildArguments` and its tests. `modes(for:)` is unchanged: the screen picks its modes explicitly, it is not a corpus mode |
| `Stratum.screen = "screen"` | `CensusCore/Corpus.swift` | Check every `switch`/`allCases` use (`census validate` prints per-stratum counts) |
| `CorpusPackage` gains `screenId: String?` and `screenCountAtSelection: Int?` | `CensusCore/Corpus.swift` | snake_case coding keys `screen_id`, `screen_count_at_selection`. Keep `spi_error_count_at_selection` for SPI; **never reuse it** for a screen count |
| `--manifest <path>` and `--resolved <dir>` on `census run`, `census resolve`, `census scan` | `census/Census.swift` (`Paths` hard-codes `corpus/packages.yaml` and `corpus/resolved`) | Default unchanged. The screen's candidates live outside `corpus/` |
| `census select screen` | `census/Select.swift` | Writes `screens/<id>/candidates.yaml`. Reuses the control-draw code: factor the shared draw out of `Control.run` rather than copying it |
| `ScreenCount` (pure function) | new, `CensusRunner/Screen.swift` | `screenCount(complete: [DiagnosticRecord], minimal: [DiagnosticRecord]) -> Int` per §5.3. **Pure and tested** |
| `ScreenStatus` and `ScreenResult` | same file | §5.4 |
| `census screen collect <id>` | `census/Screen.swift` | Reads the runs, writes `screens/<id>/results.json` and `emitters.csv` (§5.5) |
| `census select emit --from-screen <id>` | `census/Select.swift` | Samples tertiles and writes `S-emit` entries **at the screened SHA** (see Gotcha G1) |

Add no new package dependencies.

### 4.3 Data committed

```
screens/<screen-id>/
  candidates.yaml        # pinned candidates (CorpusManifest shape, stratum "screen")
  resolved/<slug>.resolved   # vendored Package.resolved per candidate
  provenance.json        # as corpus/resolved/provenance.json
  results.json           # one ScreenResult per candidate, all of them
  emitters.csv           # package_url,data_race_errors,swift_version,as_of  (select-emit compatible)
runs/<screen-id>-macos-b1 … -bN        # raw cells, normal layout, mode strict-complete-v5 and minimal-v5
runs/<screen-id>-macos-verify          # the emitter re-run (§5.6)
```

`<screen-id>` is `screen-2026-10-10`. After selection, `corpus/packages.yaml` gains the 30 `S-emit` entries and
`corpus/resolved/` gains **copies of the screened `.resolved` files** — the same bytes, so the matrix runs the
graph that was screened. Do not re-resolve.

---

## 5. Behaviour

### 5.1 Draw (`census select screen`)

Inputs: seed `20261004`, the pinned PackageList commit (D2), `--count 300`, `--active-days 365`.

- Same canonicalisation, seeded shuffle and eligibility as `Select.Control`: not archived/disabled, pushed
  within `--active-days` **of the draw date**, GitHub repo. Record the date.
- Skip every id present in `corpus/packages.yaml` (all strata, including skipped entries) — they are consumed positions.
- Pin each candidate's default-branch HEAD to a 40-char SHA at draw time (`git ls-remote`).
- `selection` text per candidate, matching `S-control`'s format: seed, draw position, PackageList commit, branch, date.
- Output is deterministic given the inputs; rerunning must produce the identical file. Test this against a
  fixed fixture list, not the network.
- Each candidate's `platforms` is `[macos-spm]`. `Stratum.screen`.

### 5.2 Resolve and build

1. **Resolve (Docker on, macOS guest off):** `census resolve --manifest screens/<id>/candidates.yaml --resolved screens/<id>/resolved --toolchain 6.4`.
   ~30 s each, ~2.5 h for 300. Candidates that fail to resolve (private or removed dependencies) are recorded
   `unresolvable` with the reason; they are **not** replaced. Resume must be safe: skip candidates already
   resolved. (Gotcha G3: the current resolver does not skip.)
2. **Quit Docker Desktop.**
3. **Screen in batches of 50**, each batch a separate run with its own fresh guest clone:
   `caffeinate -i census run --platform macos --manifest … --resolved … --run-id <screen-id>-macos-bN --package <ids…> --mode strict-complete-v5 minimal-v5`
   Batches bound guest disk growth and keep a hostile package from affecting more than 50 cells (F3 is per-run).
   Add a `--mode` filter to `census run` if it has none (`MatrixSelection.modes` exists; expose it).
4. **Early exit:** run `strict-complete-v5` for the whole batch first. Run `minimal-v5` **only** for candidates whose
   complete cell is `built` **and** has ≥1 primary non-note diagnostic. A candidate with 0 primary diagnostics
   under complete has count 0 and needs no second build. (Roughly 3 in 4 candidates skip it.)

### 5.3 The count

For a candidate with a `built` complete cell and, where required, a `built` minimal cell:

```
primaryKeys(cell) = multiset of (id ?? "text:"+text, path, line, col)
                    over records with attribution == .primary and severity != .note
screen_count      = |primaryKeys(complete) − primaryKeys(minimal)|        // multiset difference, left minus right
```

- **Severity is deliberately not in the key** (a diagnostic can be a warning in one mode and an error in the other).
  This differs from the A7 key; say so in a code comment and in ADR 0007.
- **Notes are excluded** (A8). Only `primary` attribution counts (F2): dependency diagnostics never count.
- A candidate with 0 primary diagnostics under complete: `screen_count = 0`, status `clean`, no minimal build.
- `unreadable`/`corrupt` `.dia` already turn a cell into `infra_error`; that candidate is `infra_error` here, retried once.

### 5.4 Status per candidate

| status | condition |
|---|---|
| `emitter` | complete `built`, minimal `built`, `screen_count > 0` |
| `clean` | complete `built`, and either 0 primary diagnostics or `screen_count == 0` |
| `not_screenable` | complete cell is `build_failed`, `unsupported_tools_version` or `resolve_failed`; keep the reason and `tally` |
| `minimal_failed` | complete `built` with ≥1 diagnostic but minimal not `built` (investigate any occurrence; expected ~0) |
| `unresolvable` | `census resolve` failed |
| `infra_error` | after one retry |
| `unstable` | set by §5.6 |

`ScreenResult` fields (snake_case in JSON): `package_id`, `sha`, `status`, `reason?`, `complete_outcome`,
`minimal_outcome?`, `complete_primary_diagnostics`, `minimal_primary_diagnostics?`, `screen_count?`, `batch`.

### 5.5 Collect and export

`census screen collect <id>` merges all `-bN` runs, writes `results.json` (every candidate, including every
non-emitter), `emitters.csv`, and prints a **denominator table**: drawn, unresolvable, not_screenable (by
reason), clean, emitter, unstable, infra_error. Those counts must sum to the number drawn; assert it.
`emitters.csv` columns exactly `package_url,data_race_errors,swift_version,as_of` (so `Selection.parseSPICSV`
accepts it); `swift_version` = `xcode-27.0-minimal-diff`, `as_of` = screen date. (The column name says
"errors"; it carries `screen_count`. Add a comment.)

### 5.6 Stability (A7 for the screen)

After collecting, re-run **only the emitters** (both modes) into `runs/<screen-id>-macos-verify`, in fresh
clones, batches of 50. `census compare` each emitter's complete cell against pass 1. Any emitter whose
`screen_count` differs, or whose cell outcome differs, is `unstable`: excluded from sampling, kept in the
results, counted in the denominator table. Do **not** average or pick one.

### 5.7 Selection

`census select emit --from-screen <id> --seed 20261010 --count 30`:

- Input: `results.json` emitters minus `unstable`. Tertiles via `Selection.sampleAcrossDistribution` (build
  `SPIRow`s with `errors = screen_count`; the type is named for SPI, a rename is out of scope — leave a comment).
- Write `S-emit` entries with the **candidate's pinned SHA** (G1), `platforms: [linux-spm, macos-spm]`,
  `screen_id`, `screen_count_at_selection`, `spi_error_count_at_selection: nil`, and a `selection` string
  recording seed, tertile, number of emitters, screen id.
- Copy each selected candidate's `.resolved` into `corpus/resolved/` and its `provenance.json` entry.
- Fewer than 30 emitters, or an empty tertile: take what exists, say so in the output and in ADR 0007. Do not pad.

---

## 6. Gotchas (each cost real time on this project)

- **G1 — Never re-resolve HEAD for a screen-derived entry.** The existing `Select.Emit` calls `headSHA`; that is
  right for SPI rows and **wrong here**: the screened SHA is the measurement. Branch on the source.
- **G2 — Memory.** Docker and the guest cannot coexist (above). The resolve phase needs Docker; the screen needs it off.
- **G3 — Resume.** `Resolver.resolve` re-fetches and re-resolves every package it is given and rewrites
  `provenance.json` after each; add skip-if-present with an explicit `--force`.
- **G4 — Classifier markers.** `OutcomeClassifier.resolutionFailureMarkers` once matched "unable to resolve
  module dependency: 'UIKit'" and misfiled iOS-only packages. If you see surprising `resolve_failed`, run
  `census reclassify runs/<id>` (dry run) before believing it.
- **G5 — Dependency warnings are suppressed by SwiftPM.** A root's `transitive` bucket holds only errors.
  Irrelevant to the screen (primary only) but do not "fix" it.
- **G6 — Empty `.dia` files are normal** after a failed build; non-empty unparseable ones invalidate the cell.
- **G7 — Guest first boot can stall** at "boot scripts must have finished". `GuestVM.create()` polls SSH
  and the firewall rather than trusting `limactl start`. Do not "simplify" that away.
- **G8 — pf must never block established flows to 192.168.5.1** (it hangs Lima's SSH ControlMaster). Do not edit
  `tools/vm/pf.census.conf` without reading ADR 0006's firewall section.
- **G9 — Swift 6 language mode in `tools/`.** New types must be `Sendable`; `YAMLEncoder` needs `sortKeys`
  for deterministic output.
- **G10 — `Mode.allCases` feeds `run.json`.** Adding `minimal-v5` changes future manifests' `modes` list; that is
  intended; do not touch committed runs.

---

## 7. Tests (swift-testing, in `tools/Tests/`)

Write the failing test first. The pure parts carry the risk and get the tests:

- **`screenCount`**: identical builds → 0; complete adds 3 → 3; a diagnostic present in both but at a moved
  line counts as added; **multiset semantics** (complete has 2 of a key, minimal 1 → 1); notes ignored;
  non-primary ignored; severity changing between modes does **not** create a difference; order-independent.
- **status classification**: one test per row of §5.4, including the sums-to-drawn assertion.
- **draw determinism and disjointness**: fixed fixture list + fixed seed → golden order; a corpus containing
  ids from the list → those ids are skipped and the next ones taken; same inputs twice → identical bytes.
- **`BuildInvocation`**: `minimal-v5` contains `-strict-concurrency=minimal`, still forces `-swift-version 5`,
  never contains `complete`; existing modes unchanged.
- **`emitters.csv`** round-trips through `Selection.parseSPICSV`.
- **`select emit --from-screen`**: keeps the screened SHA; refuses `unstable`; copies the `.resolved` bytes
  unchanged (compare SHA-256); does not touch `spi_error_count_at_selection`.
- **`CorpusPackage` coding**: new fields round-trip; old `packages.yaml` still decodes.
- Existing suites stay green (currently 70+ tests). `census validate` passes on the final `packages.yaml`.

---

## 8. Relationship to SPI data

If the SPI export later arrives, **do not re-draw `S-emit`.** Use it as a *validation join*: per package, SPI's
count against the screen's count. That measures how much SPI's declared-mode figure differs from the
strict-complete-v5 measurement (ADR 0001's open question; ADR 0002's censoring claim) and is a finding in its own
right. The two selection signals must not be mixed in one stratum.

---

## 9. Known biases — state them in ADR 0007 and in the M3 write-up

1. **Selected on the outcome.** `S-emit` is truncated at zero by construction. Never pool it with `S-control`
   without stated weights.
2. **iOS-only packages are `not_screenable`.** SPI includes them (its iOS builds use `xcodebuild`); we do not.
   The size of this exclusion is reported as a number: it is in the denominator table.
3. **One toolchain defines membership.** Packages that emit only on other toolchains are missed.
4. **A failed build censors.** A `build_failed` candidate may emit; we cannot see it. It is excluded, not zero.
5. **`-strict-concurrency=minimal` as the baseline** is a choice; the differential counts what strict checking
   *adds to Swift 5 mode's defaults*, which is what a migrating developer experiences.
6. **"Active" is approximated** by a GitHub push within 365 days (ADR 0004 §5).

---

## 10. Runbook (the order matters)

1. Owner confirms §2. Write and commit ADR 0007 (pre-registration). **Stop here if the owner has not confirmed.**
2. TDD the code in §4.2 (draw, mode, count, status, collect, select). `swift test` green. Commit.
3. Dry run on **5** candidates end to end: draw `--count 5` to a scratch file (not `screens/`), resolve, run both modes in one
   batch, collect, check the denominator sums. Delete the scratch artefacts. Do not skip this: three of this
   project's worst bugs were found by the first real run.
4. Draw 300. Commit `candidates.yaml`.
5. Resolve all (Docker on). Commit `resolved/` and `provenance.json`.
6. Quit Docker. Screen in batches of 50 under `caffeinate -i`. Between batches, `limactl list` (no stray
   instances) and `df -h /`. Commit each batch's run directory.
7. `census screen collect`. Apply D5 if emitters < 45 (one extension, back to step 4's draw for the next 150).
8. Verify pass over the emitters (§5.6). Collect again.
9. `census select emit --from-screen`. `census validate`. Commit `corpus/` changes.
10. Fill ADR 0007's results section. Update `runs/README.md` and `corpus/README.md`. Relaunch Docker Desktop.
11. Report: the denominator table, counts per tertile, instabilities, and anything unexpected. **Hand back; do not
    proceed to the `S-emit` matrix runs** — that is the next task.

Expected wall time: ~2.5 h resolve + ~7–10 h screen + ~1.5 h verify, mostly unattended.

---

## 11. Acceptance

- ADR 0007 committed **before** any screen run, and unchanged after (check `git log -- docs/decisions/0007*`).
- `screens/screen-2026-10-10/results.json` has one entry per drawn candidate; the denominator table sums to the draw.
- 30 `S-emit` entries (or fewer, stated) in `corpus/packages.yaml`, each at its screened SHA, each with its
  screened `.resolved` byte-identical in `corpus/resolved/`.
- Every selected entry's pass-1 and verify-pass `screen_count` agree.
- `census validate`, `swift test`, and `census compare` on the verify run all pass.
- No existing committed run directory was modified.
- The agent's report states plainly what the emit rate was, what was excluded and why, and what it did **not** verify.

## 12. Out of scope

Running `S-emit` through the five Linux toolchains and the macOS pair; evaluating the redefined G2; M2 anything;
a concurrency-family classifier; `xcodebuild`/iOS builds; refreshing the PackageList; changing `S-control`,
`S-anchor` or `S-byproduct`; any SPI scraping; `entries/`.
