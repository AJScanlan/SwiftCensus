# SPEC.md — swift-diagnostic-census

> Working title. Rename freely; `census` is deliberate — it signals *measurement first*,
> which is the load-bearing design decision in this document.

**Status:** pre-M0. Nothing built.
**Owner:** AJ Scanlan
**Last revised:** 2026-08-11

---

## 0. Summary

An instrument that compiles a pinned corpus of Swift packages across a matrix of
toolchains with strict concurrency checking enabled, captures every emitted
diagnostic, normalises it to a stable compiler-internal identifier, and publishes
the resulting frequency distribution.

The measurement is the product. A verified, version-pinned knowledge base of
diagnostic explanations is an *optional downstream artifact* built from the
ranking, not the goal.

---

## 1. Problem

Three separate facts, which together define the gap:

1. **Swift concurrency knowledge rots silently.** Blog posts, Stack Overflow
   answers, and LLM weights all encode advice that was correct for one toolchain
   and is wrong for the next. Nothing in the ecosystem detects this. There is no
   staleness signal anywhere in the chain from author to reader.

2. **Nobody knows which diagnostics actually matter.** Swift Package Index runs
   `-strict-concurrency=complete` across the entire index (11,500+ packages,
   ~350k builds/month) and publishes two aggregate numbers: packages with zero
   data-race diagnostics, and total diagnostic count. The *distribution by
   diagnostic kind* is discarded at aggregation time. So the ecosystem knows how
   many errors exist and not which ones.

3. **The pieces of a good answer exist but are not joined.** The official
   migration guide has the model. `swiftlang/swift/test/Concurrency/*.swift` has
   thousands of minimal reproductions with `// expected-error` assertions.
   Educational notes ship as markdown *inside the toolchain* and no tool renders
   them. ConcurrencyRecipes has curated prose. None of these is keyed to a
   toolchain version, and none is machine-verified against the compiler that ships
   today.

Nothing joins **stable diagnostic ID → verified minimal repro → toolchain matrix →
mechanism explanation**. Every existing artifact has two or three of the four.

---

## 2. Non-goals

Explicit, because scope creep is the primary failure mode for this project.

- **Not** a tutorial site, a course, or a "learn Swift concurrency" resource.
- **Not** a replacement or competitor for the official migration guide. If the
  guide covers something adequately, that thing does not get an entry — link out.
- **Not** a replacement for Swift Package Index. This consumes the same idea at a
  smaller scale and finer granularity; upstreaming is a goal, forking is not.
- **Not** general Swift. v1 scope is concurrency and data-race safety diagnostics
  only. Other diagnostic families are a v2 question and must not be started early.
- **No** human contribution flow: no submissions, no accounts, no moderation, no
  reputation. Contributions are PRs against a git repo like any other project.
- **No** dynamic web application. Static output only (JSON + markdown + GitHub Pages).
- **No** LLM-generated entry text committed without human review. Drafting with an
  agent is fine; unreviewed prose in the corpus defeats the point of the project.

---

## 3. Design principles

These are decisions, not suggestions. An agent working on this repo should not
reverse them without an explicit conversation.

**P1 — Measure, don't curate.** Entry selection is driven by an empirical
frequency ranking, never by "things the author happened to hit." Diary-sourcing
has a hard ceiling at one person's problem surface and is the reason this design
was revised.

**P2 — The instrument ships before the corpus.** M0–M3 produce a working
measurement pipeline and a published finding with zero entries written. Everything
after M3 is optional. This is the anti-stall device; treat the M3 boundary as real.

**P3 — Every claim is an assertion the CI can fail.** Entry matrices contain
`expect` values, not descriptions. If the compiler stops agreeing, CI opens an
issue. A knowledge base without a staleness detector is a liability, because
agents will retrieve confidently wrong answers.

**P4 — Reuse the compiler's own harness.** `swift-frontend -typecheck -verify`
already consumes inline `// expected-error {{...}}` annotations. Do not write a
bespoke diagnostic assertion framework.

**P5 — Reuse the compiler's own repros.** Entry reproductions are lifted from
`swiftlang/swift/test/Concurrency/` where a suitable one exists (with attribution
and license note). The scarce input is *mechanism explanation*, not repro code.

**P6 — Stable IDs over message text.** Diagnostic wording changes between
releases. Group by the compiler-internal diagnostic identifier, not by the
rendered string. See §5.2.

**P7 — Pinned corpus.** Packages are pinned to git SHAs. Frequency data across
toolchain runs is only comparable if the source is held constant. "Latest" is
forbidden in the corpus manifest.

**P8 — Coverage is reported as a number.** Every published entry set states what
fraction of observed diagnostics it covers. This is what makes the project
*finishable*; see §7.

---

## 4. Architecture

```
corpus manifest ──> matrix runner ──> raw diagnostics ──> normaliser ──> census
                         │                                                  │
                         │                                                  ├─> report (markdown)
                         │                                                  ├─> census.json
                         │                                                  └─> ranking (drives entries)
                         │
                    entries ──> verifier (swift-frontend -verify) ──> drift issues
                         │
                         └──> index.json ──> llms.txt / MCP server
```

### 4.1 Corpus

`corpus/packages.yaml`. Tiered so the matrix can be run cheaply during development
and widened later.

| Tier | Contents | Rough size |
|---|---|---|
| T0 | LedgerKit's own dependency graph | ~5–10 |
| T1 | Point-Free packages, swift-nio, swift-collections, swift-algorithms, swift-async-algorithms, Vapor core | ~15–20 |
| T2 | Top SPI packages by dependent count, filtered to those that build on Linux or macOS via SwiftPM | ~20–100 |

v0 target: T0 + T1 (~30 packages). That is enough for a frequency distribution.
T2 is a scaling exercise, not a prerequisite.

Each entry pins `url`, `sha`, `platforms`, and an optional `skip_reason`.

### 4.2 Matrix runner

Dimensions:

- **toolchain**: the last three releases, the current release, and a nightly.
  Nightly is the highest-value column — it detects diagnostic changes *before*
  they ship, which is information no blog post and no model can have.
- **platform**: `macos-spm` (primary), `linux-spm` (pure-Swift packages, cheap
  runners), `macos-xcodebuild` (packages requiring Apple SDKs only).
- **mode**: `strict-complete` (`-strict-concurrency=complete` under the package's
  declared language mode) and `swift6` (`-swift-version 6`). Run both; they
  produce materially different diagnostic sets.

To keep results comparable to SPI's published figures, `strict-complete` must
match their invocation: pass `-strict-concurrency=complete` to `swift build` or
`xcodebuild` regardless of what the package declares.

**Compute.** SPI runs this on a Mac mini fleet under Orka; that is not replicable
and not necessary. A single Mac mini overnight handles ~30 packages × 5 toolchains.
Linux GitHub Actions runners are 1× cost and cover the pure-Swift subset; macOS
runners are 10× and should be reserved for the Apple-SDK-only set. Budget the
matrix accordingly — a full run is a scheduled weekly job, not a per-commit job.

### 4.3 Diagnostic capture

**This is the first real technical unknown and M0 exists to resolve it.** Three
candidate routes, in descending order of expected robustness. Validate empirically;
do not assume.

1. **`.xcresult` bundles** (macOS/xcodebuild). `xcodebuild -resultBundlePath` then
   `xcrun xcresulttool get --format json`. Structured and complete. Caveat: the
   `xcresulttool` CLI changed shape in Xcode 16 and older invocations now need
   `--legacy`; pin the invocation per toolchain.
2. **Serialized diagnostics (`.dia`)**. SwiftPM emits these into `.build/`. Binary
   (Clang's serialized diagnostic format). `swift-tools-support-core` contains a
   parser used by SwiftPM itself — verify whether it is public API before
   committing to this route.
3. **stderr parsing** with `-Xswiftc -diagnostic-style=llvm` for a stable
   single-line-per-diagnostic format. Fragile across versions but trivially
   implementable and adequate for M0.

Recommendation: build M0 on route 3 to prove the pipeline end-to-end, then harden
to route 1 or 2 in M1 once the shape of the data is known.

### 4.4 Normalisation

See §5.2. Output is one record per emitted diagnostic, keyed to a stable
identifier rather than rendered text.

### 4.5 Entries (M4+, optional)

An entry is a directory, not a document:

```
entries/<diagnostic-id>/
  manifest.yaml
  Repro.swift          # must produce the diagnostic
  Resolution-A.swift   # must compile clean
  Resolution-B.swift   # optional, when a real tradeoff exists
  NOTES.md             # mechanism, tradeoffs, when each resolution applies
```

### 4.6 Distribution (M5, optional)

One build step, three surfaces:

- `dist/index.json` — the machine-readable join of census + entries.
- `dist/llms.txt` and `dist/llms-full.txt` on GitHub Pages. Note the honest
  assessment: llms.txt does approximately nothing for search-engine citation, but
  IDE agents do fetch it. Ship it as forward-compatible plumbing, not as a
  visibility play.
- A thin MCP server whose primary tool takes a raw diagnostic string and returns
  matching entries with their matrix rows.

---

## 5. Data schemas

### 5.1 Corpus manifest

```yaml
# corpus/packages.yaml
schema_version: 1
packages:
  - id: pointfreeco/swift-dependencies
    url: https://github.com/pointfreeco/swift-dependencies
    sha: <40-char-sha>
    tier: 1
    platforms: [macos-spm, linux-spm]
  - id: apple/swift-nio
    url: https://github.com/apple/swift-nio
    sha: <40-char-sha>
    tier: 1
    platforms: [macos-spm, linux-spm]
```

### 5.2 Normalisation — stable diagnostic IDs

The critical design decision. Emitted messages interpolate identifiers
(`sending 'self.foo' risks causing data races`) and get reworded between releases,
so neither raw text nor a naive template is a stable key.

**Primary strategy.** The compiler declares every diagnostic in
`swiftlang/swift/include/swift/AST/Diagnostics*.def` with an internal identifier
and a format string. Fetch those files at the git tag matching each toolchain,
parse out `(identifier, format_string)` pairs, convert format strings to regexes
(handling `%0`, `%1`, `%select{a|b}`, `%error`, etc.), and match emitted messages
against them. The resulting internal identifier — e.g. `sending_risks_data_race` —
is stable across releases even when the user-visible wording changes.

This also gives §6's drift detection for free: an identifier whose format string
changed between two tags is, by definition, a diagnostic whose wording drifted.

**Fallback strategy.** If format-string matching proves too brittle: strip
single-quoted identifiers to `<id>`, strip type names, hash the residue. Coarser
and unstable across rewording, but functional.

**Secondary key.** Swift now emits diagnostic groups as `[#GroupName]` appended to
the message. Capture this when present as a coarse category, but do not rely on it
as the primary key — coverage across diagnostics is incomplete.

### 5.3 Census record

```json
{
  "schema_version": 1,
  "run_id": "2026-08-11T02:00Z",
  "diagnostic_id": "sending_risks_data_race",
  "group": "Sendable",
  "severity": "error",
  "format_string": "sending %0 risks causing data races",
  "observations": {
    "total_occurrences": 1284,
    "distinct_packages": 22,
    "distinct_modules": 61,
    "by_toolchain": { "6.1": 1402, "6.2": 1284, "6.3-dev": 907 }
  },
  "example_sites": [
    { "package": "apple/swift-nio", "file": "...", "line": 214, "rendered": "..." }
  ]
}
```

### 5.4 Entry manifest

```yaml
# entries/sending_risks_data_race/manifest.yaml
schema_version: 1
diagnostic_id: sending_risks_data_race
group: Sendable
title: "sending a non-Sendable value across an isolation boundary"

matrix:
  - toolchain: "6.1"      platform: macos-spm   expect: error
  - toolchain: "6.2"      platform: macos-spm   expect: error
  - toolchain: "6.3-dev"  platform: macos-spm   expect: warning   # drift under watch

resolutions:
  - file: Resolution-A.swift
    summary: "conform the type to Sendable"
    tradeoff: "forces Sendable through the entire reachable type graph"
  - file: Resolution-B.swift
    summary: "hop through an actor"
    tradeoff: "adds one suspension point per call; changes reentrancy behaviour"

sources:
  - kind: compiler-test
    ref: "swiftlang/swift@<sha>:test/Concurrency/sendable_checking.swift"
  - kind: forums
    ref: "https://forums.swift.org/t/..."

last_verified: 2026-08-11
```

`expect` is an **assertion**. CI fails when reality diverges. That is the entire
point of the field.

---

## 6. Drift detection

Two independent detectors, both running on the weekly job.

**Census drift.** Between two toolchains: which diagnostic IDs appeared, which
disappeared, which changed format string, and which changed occurrence count by
more than a threshold. Output is a markdown diff report. Run against nightly, this
is an early-warning system for the Swift community and is arguably the most
valuable single output of the project.

**Entry drift.** For each entry, run the `expect` matrix via
`swift-frontend -typecheck -verify` on `Repro.swift` and a clean-build check on
each `Resolution-*.swift`. Any mismatch opens a GitHub issue tagged
`drift/<diagnostic-id>` and marks the entry `stale` in `index.json`. **Stale
entries are excluded from `llms.txt` and MCP output** — serving a stale entry to
an agent is worse than serving nothing.

---

## 7. Definition of done

The project is finishable, and this section is what makes it so.

**M3 is the ship line.** At M3 the project has produced a working measurement
instrument and a published empirical result. If nothing further is built, the work
is complete and standalone.

**For the entry corpus (M4), done is a stated coverage number.** Because the
census provides a denominator, coverage is computable:

- `occurrence_coverage` = Σ occurrences of entries' diagnostic IDs ÷ Σ all occurrences
- `package_coverage` = distinct packages affected by covered IDs ÷ distinct packages with any diagnostic

Report both. Occurrence counts are dominated by a small number of pathological
packages; package counts measure breadth. **Rank primarily by distinct packages
affected, secondarily by occurrences** — a diagnostic that fires 800 times in one
package is a property of that package, not of the ecosystem.

**The denominator is the residual, not the total.** Raw frequency overstates the
value of the head, because the most frequent diagnostics are the best-documented
ones — the migration guide covers them, every blog post covers them, and every
model has seen them thousands of times. Frequency and documentation-gap are
anti-correlated. So M2 must compute a third figure:

- `residual` = occurrences of diagnostic IDs **not** adequately covered by the
  migration guide, ConcurrencyRecipes, or a rendered educational note

M4's coverage target is stated against the residual. Declare it before starting
(suggested: 85% residual coverage) and stop when hit. "Entries covering 87% of
under-documented data-race diagnostics across 34 packages and 5 toolchains" is a
finished artifact. "Twenty things I ran into" is not.

Determining "adequately covered" requires judgement and cannot be fully automated.
A cheap first pass: string-match the diagnostic's format string and group name
against the migration guide and ConcurrencyRecipes text, then hand-adjudicate the
top 40. Record the adjudication in `corpus/coverage-audit.yaml` so it is
reproducible and arguable.

---

## 8. Milestones

Each has a single, checkable exit condition. No milestone begins before its
predecessor's exit condition is met.

**M0 — Capture spike.**
Build one package, one toolchain, capture diagnostics, emit JSON.
*Exit:* a committed `samples/m0.json` containing parsed diagnostics from one real
package, and a written decision on which of §4.3's three capture routes to use.

**M1 — Matrix runner.**
Corpus manifest with pinned SHAs. Runner over N packages × M toolchains ×
platforms. Raw output committed per run.
*Exit:* one full reproducible run over T0+T1, results committed, re-running on the
same inputs produces byte-identical diagnostic sets.

**M2 — Normalisation and ranking.**
`Diagnostics*.def` parser, format-string matcher, aggregation, `census.json`,
ranked markdown report with both coverage denominators.
*Exit:* a ranked table of diagnostic IDs by distinct-packages-affected, with the
top 10 manually spot-checked against raw build logs for correctness.

**M3 — Publish the finding. ← SHIP LINE**
Write up the distribution: how concentrated it is, what dominates, how it shifts
across toolchains, what the nightly column predicts.
*Exit:* published on ajscanlan.dev, repo public with README pointing at
`census.json`. **Project is complete here.**

**M4 — Entries (optional).**
Entry schema, `-verify` harness, drift detection, entries written top-down from
the ranking with repros lifted from the compiler test suite.
*Exit:* stated coverage target reached, CI green, drift detector demonstrated by
deliberately breaking one entry's matrix.

**M5 — Distribution (optional).**
`index.json`, `llms.txt`, MCP server. Wired into LedgerKit's `.claude/` as the
first consumer.
*Exit:* an agent working in LedgerKit successfully retrieves a relevant entry from
a raw compiler diagnostic without the diagnostic ID being supplied by hand.

**Upstream (opportunistic, any time after M2).**
Propose diagnostic-kind breakdown to Swift Package Index, with M2 results in hand
as evidence. SPI is open source and now part of Apple; they already generate the
data and discard the structure. Small change to an existing pipeline, very large
leverage. Do not block any milestone on this — it runs on someone else's review
cycle.

---

## 9. Open questions

To be resolved empirically, not by argument.

1. **Capture route** (§4.3). M0 resolves this.
2. **Does SPI expose per-build logs publicly?** If build logs with full diagnostic
   output are retrievable, M1's corpus can be enormously wider for near-zero
   compute. Check before building the runner — this could change the whole shape
   of the project. Investigate `swiftpackageindex.com` build pages and the
   open-source repo.
3. **Format-string matching coverage.** What fraction of emitted diagnostics
   successfully match a `.def` format string? If below ~90%, the fallback in §5.2
   becomes primary. Measure in M2 and report the match rate as a data-quality figure.
4. **What shape is the distribution, and what does each shape imply for M4?**
   Not a go/no-go — a fork. The two variables are concentration and
   documentation-gap, and they pull in opposite directions (§7).

   - **Concentrated, head under-documented.** Best case. Small number of
     hand-authored entries, high coverage, clean finish. Rare; if the head were
     under-documented it probably wouldn't be the head.
   - **Concentrated, head well-documented.** Skip M4 entirely. Writing a fourth
     explanation of `sending` diagnostics adds nothing. Go straight to M5 with a
     census-only index: diagnostic ID, format string, real occurrence sites,
     version matrix, links out to the canonical explanation. Still useful to an
     agent, and requires no prose.
   - **Dispersed.** The mass sits in the tail, which is exactly where models fail
     and no documentation exists. M4 is worth *more* here, not less — but only in
     **mined** form, never hand-authored. See below.
   - **Dispersed and the tail is mostly noise** (one-off diagnostics in
     abandoned packages). End at M3. This is the only genuine no-go and it is an
     acceptable outcome.

   **Mined entries.** Because the corpus is SHA-pinned, a package that emits
   diagnostic X at SHA A and not at SHA B gives you a real fix diff for free. That
   is resolution-sourcing at tail scale with zero authoring. In the dispersed case
   an entry degrades to: diagnostic ID + format string + N occurrence sites + M fix
   diffs + version matrix, with `NOTES.md` written **only** where there is genuine
   mechanism insight the ecosystem lacks. Most entries will have no `NOTES.md`,
   and that is correct.
5. **Licensing of lifted repros.** `swiftlang/swift` is Apache 2.0 with Runtime
   Library Exception. Confirm attribution requirements before lifting test files
   and record the conclusion in `NOTICE`.

---

## 10. Prior art

Do not rebuild these. Link to them.

| Artifact | What it has | What it lacks |
|---|---|---|
| swift.org migration guide | Canonical model, written with the compiler team | Not exhaustive on failure modes; no version keying |
| ConcurrencyRecipes (Massicotte) | Curated problem→solution prose | Not compiled, not CI-checked, not toolchain-pinned |
| `swiftlang/swift/test/Concurrency/` | Thousands of verified minimal repros | No mechanism explanation; unreachable by problem-solvers |
| Toolchain educational notes | Long-form explanations, versioned with the toolchain | Ship as markdown inside the toolchain; **nothing renders them** |
| SPI "Ready for Swift 6" | Ecosystem-scale strict-concurrency builds | Aggregates to counts; discards diagnostic-kind breakdown |
| Swift Forums | Compiler-team answers | Unstructured, undiscoverable |

The stretch goal worth remembering: **render the toolchain's shipped educational
notes and join them to census IDs.** They are already written, already correct,
already versioned, and currently visible to nobody. Pure externalisation of
existing work — zero new knowledge production, real commons contribution.
There is an open issue on `swiftlang/swift-org-website` asking for exactly this index.

---

## 11. Repo layout

```
.
├── SPEC.md
├── README.md
├── NOTICE
├── corpus/
│   └── packages.yaml
├── tools/                    # the instrument (Swift package)
│   ├── Sources/
│   │   ├── CensusRunner/     # matrix execution
│   │   ├── DiagParse/        # capture + .def format-string matching
│   │   ├── CensusCore/       # aggregation, ranking, coverage math
│   │   └── EntryVerify/      # -verify harness, drift detection
│   └── Package.swift
├── runs/
│   └── 2026-08-11/           # raw per-run output, committed
├── census.json               # latest aggregated census
├── reports/
│   └── 2026-08-11.md         # generated ranking + drift report
├── entries/                  # M4+
├── dist/                     # M5+ — index.json, llms.txt, MCP manifest
└── .github/workflows/
    ├── census.yml            # weekly cron, full matrix
    └── verify-entries.yml    # per-commit, entries only
```

---

## 12. Notes for an agent working in this repo

- **Read §2 and §3 before proposing anything.** Most plausible-sounding
  suggestions in this problem space are things that have already been considered
  and rejected. Do not reintroduce a submission flow, a web app, a moderation
  system, or coverage of non-concurrency diagnostics.
- **Never advance a milestone whose predecessor's exit condition is unmet.**
- **Do not commit generated entry prose without review.** Drafting is fine;
  unreviewed text in `entries/*/NOTES.md` defeats the project's premise.
- **`expect` fields are assertions.** If a check fails, the correct response is to
  investigate whether the compiler changed — not to relax the assertion.
- **Corpus SHAs are pinned deliberately.** Bumping them invalidates cross-run
  comparability. Bumps are a deliberate, documented operation with a fresh
  baseline run, never a drive-by update.
- **Prefer deleting scope to deferring it.** An item moved to "later" is scope this
  project is carrying; an item deleted is not.
