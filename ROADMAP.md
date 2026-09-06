# ROADMAP.md — swift-diagnostic-census

**Status:** pre-M0.
**Owner:** AJ Scanlan
**Written:** 2026-09-05
**Governs:** execution. `SPEC.md` governs intent and remains authoritative on §2 (non-goals)
and §3 (design principles).

---

## 0. How to use this document

`SPEC.md` is the design record and is deliberately unedited. This document is the
executable layer. Where the two disagree, §1 below states why, cites the evidence,
and says what it deletes or adds. Everything not amended in §1 stands as written.

Three rules carried forward verbatim from SPEC §12, because they are the ones most
likely to be broken by an agent working quickly:

- Never advance a milestone whose predecessor's exit condition is unmet.
- `expect` fields are assertions. A failing check is investigated, not relaxed.
- Prefer deleting scope to deferring it.

---

## 1. Amendments to SPEC

Each amendment was established empirically on 2026-09-05 against Swift 6.4
(swiftlang-6.4.0.30.4) / Xcode 27.0 beta 5 on macOS 27, unless stated otherwise.

### A1 — Stable diagnostic IDs come from the compiler, not from `Diagnostics*.def`

**Amends:** §5.2 (primary strategy), §4.3, §9.3.

`swift-frontend` accepts `-debug-diagnostic-names`, which prints the internal
diagnostic identifier inline, and `-print-diagnostic-groups`, which prints the
group. Both pass through SwiftPM via `-Xswiftc` under the current default build
system. Verified output:

```
warning: capture of 'v' with non-Sendable type 'NotSendable' in a '@Sendable'
  closure; ... [non_sendable_capture] [#SendableClosureCaptures]
error: call to main actor-isolated global function 'onMain()' in a synchronous
  nonisolated context [actor_isolated_call_decl] [#ActorIsolatedCall]
note: add '@MainActor' to make global function 'offMain()' part of global actor
  'MainActor' [add_globalactor_to_decl]
```

Flag availability in `include/swift/Option/Options.td` at release tags:

| Tag | `-debug-diagnostic-names` | `-print-diagnostic-groups` |
|---|---|---|
| `swift-6.0-RELEASE` | present | **absent** |
| `swift-6.1-RELEASE` | present | present |
| `swift-6.2-RELEASE` | present | present |
| 6.4 (local) | present | present |

**Deletes:** the `.def` fetcher, the format-string→regex converter, `%0`/`%select{}`/
`%error` handling, the §5.2 fallback hashing strategy, and Open Question 3 (match
rate is 100% by construction, not a measured data-quality figure).

**Adds:** an M0 check that both flags behave identically across every toolchain in
the matrix. `-print-diagnostic-groups` absent at 6.0 is why 6.0 leaves the matrix (A6).

**Residual risk, stated plainly:** `-debug-diagnostic-names` is a debug flag with no
stability guarantee. Mitigation is cheap and mandatory: **every census record stores
both the identifier and the verbatim rendered message.** If a future toolchain drops
or renames the flag, the `.def` matcher described in SPEC §5.2 remains the documented
contingency. It is not built now. It is not deleted from the SPEC either.

### A2 — `strict-complete` is the only frequency source; `swift6` is demoted — **AMENDED by ADR 0002**

**Amends:** §4.2 (mode), §5.3 (`by_toolchain`), §8 M1.

SPEC §4.2 says the two modes "produce materially different diagnostic sets." That
understates the problem. Under `-swift-version 6` these diagnostics are errors, the
frontend halts, and every downstream diagnostic is never emitted. The same source
file produced **1 diagnostic under `-swift-version 6` and 3 under Swift 5 language
mode + `-strict-concurrency=complete`**.

Swift Package Index reached the same conclusion independently and documents it: if
type checking produces errors the compiler does not proceed to code generation, so
`-swift-version 6` shows fewer errors than actually exist.

**Consequence:** `swift6`-mode occurrence counts are censored, not measured. They
cannot be aggregated, ranked, or compared across toolchains without producing a
number that looks like a frequency and is not one.

**Decision:** `strict-complete` (Swift 5 language mode + `-strict-concurrency=complete`)
is the sole input to `census.json` occurrence counts. `swift6` mode is retained only
as a **severity overlay** — run on a small subset to answer "which IDs are errors
rather than warnings under Swift 6" — and its records are tagged `censored: true` and
excluded from all ranking.

**Resolved 2026-09-06 — see `docs/decisions/0002-language-mode-censoring.md`.**
`-show-diagnostics-after-fatal` recovers nothing, and no `--continue-building-after-errors`
option exists on `swift build`.

**More importantly, ADR 0002 found this amendment incomplete.** "Under the package's
declared language mode" (SPEC §4.2) means a package declaring `swift-tools-version: 6.x`
*is* in Swift 6 mode — so A2's censoring applies to the very mode A2 nominated as safe.
Measured on identical source: 4 diagnostics under `tools-version: 5.10`, **1** under
`tools-version: 6.0`, and 4 again with `-swift-version 5` forced.

The primary mode is therefore **`strict-complete-v5`** — `-strict-concurrency=complete`
with `-swift-version 5` forced for every package regardless of declaration.
`strict-complete-declared` is retained for SPI comparability but is not a frequency
source. `swift6` as a separate mode is deleted.

### A3 — The corpus is stratified on evidence, not selected on prestige

**Amends:** §4.1 entirely (replaces the T0/T1/T2 tiering).

SPI's published "Ready for Swift 6" dataset, at its last data point (Swift 6.1):

| Set | Clean packages | Total | % clean |
|---|---|---|---|
| All active packages | 2,027 | 3,395 | 60% |
| Apple packages | 54 | 65 | **83%** |
| SSWG incubated | 31 | 32 | **97%** |

SPEC §4.1's T0+T1 — Point-Free, swift-nio, swift-collections, swift-algorithms,
swift-async-algorithms, Vapor core — *is* the Apple/SSWG stratum, which is 83–97%
clean. swift-nio reports `Swift 6 data race errors: 0` on every platform at 6.1, 6.2
and 6.3. A census over T0+T1 risks a near-empty distribution and fails M2 before M3
can ship.

This is also a P1 violation: a corpus chosen because the packages are well-known is
curated, just at a different level than entry selection.

**Replacement strata:**

| Stratum | Selection rule | Target size | Purpose |
|---|---|---|---|
| `S-emit` | SPI-reported data-race error count > 0, sampled across the count distribution (head / middle / long tail) | ~30 | Where the signal is |
| `S-control` | Uniform random sample of SPI-active packages, unconditioned on error count | ~20 | Base rate; guards the ranking against selection bias |
| `S-anchor` | swift-nio, swift-collections, a Point-Free package, one Vapor core | ~5 | Comparability to SPI; drift canaries; mostly clean by design |
| `S-byproduct` | LedgerKit's own dependency graph (SPEC's original T0) | ~8 | Closes the byproduct loop; **not** a signal source |

`S-byproduct` is restored from SPEC §4.1's T0 and exists for a reason unrelated to
measurement. The origin reasoning identifies distribution as the hard half of this
project, settled by one up-front decision: *the first consumer is you, on LedgerKit.*
A corpus that ships as a website first dies. Keeping LedgerKit's graph in the corpus
means the instrument is pointed at code you actually maintain, so that if M4 ever
happens the retrieval loop already has a real consumer. Its diagnostics are recorded
and reported separately; they are **excluded from the ecosystem ranking**, because
n=1 on your own dependency graph is exactly the diary-sourcing bias P1 exists to
prevent.

`S-control` is not optional. Without it, every frequency in the census is conditioned
on "SPI saw an error here in May 2025" and the ranking is not a property of the
ecosystem.

**Known limitation, must be documented in the published report:** SPI's chart data
has not updated since **2025-05-07 (Swift 6.1)**. The selection signal is ~16 months
stale. That is acceptable for a *sampling frame* — it is not a result — but it must
be stated, and it is precisely what `S-control` exists to bound.

Manifest fields per SPEC §5.1, plus `stratum` and `spi_error_count_at_selection`.

### A4 — Capture route 3 is the answer, not the stepping stone — **SUPERSEDED by ADR 0001**

**Amends:** §4.3 (recommendation and route descriptions), §8 M0 exit.

SPEC §4.3 recommends building M0 on stderr parsing, then hardening to `.xcresult` or
`.dia`. That ordering inverts, because **route 3 is the only route verified to carry
the stable identifier.** `.dia` and `.xcresult` are structured, but nothing yet shows
they preserve `-debug-diagnostic-names` output. Structure is worth less than the key.

Also amended:

- SwiftPM's default build system is now **`swiftbuild`**; `native` (llbuild) is marked
  deprecated in `swift build --help`. `.dia` files still land, but under
  `.build/out/Intermediates.noindex/<Module>.build/.../Objects-normal/<arch>/*.dia`,
  not where §4.3 route 2 assumes.
- Required invocation flags: `-diagnostic-style=llvm`, `-no-color-diagnostics`,
  `-debug-diagnostic-names`, `-print-diagnostic-groups`.
- The parser must handle three artifacts observed in real output:
  1. **ANSI colour codes**, emitted even when `-diagnostic-style=llvm` is requested,
     because the build system injects `-color-diagnostics`.
  2. **OSC-8 terminal hyperlinks** wrapping group names — the group renders as
     `[#\e]8;;https://docs.swift.org/...\GroupName\e]8;;\]`.
  3. **Duplicate emission.** The same diagnostic appears once per frontend job that
     sees it (`emit-module` and `compile` both emit) and the `swift` diagnostic style
     prints each twice. Deduplicate on
     `(diagnostic_id, relative_path, line, col, severity)`.

**Resolved 2026-09-06 — see `docs/decisions/0001-capture-route.md`.** `.dia` preserves
the identifier, and `TSCUtility.SerializedDiagnostics` is public API. **Route 2 is the
capture route.** The ANSI/OSC-8/double-emission handling above applies only to the
stderr fallback, which is retained for build configurations emitting no `.dia`. Route 1
(`.xcresult`) is deleted, not deferred.

### A5 — The residual denominator is largely computable

**Amends:** §7 ("Determining 'adequately covered' requires judgement and cannot be
fully automated").

SPEC §10's stretch goal — "render the toolchain's shipped educational notes" — is
already done by Swift.org. `docs.swift.org/compiler` is a DocC archive of **79
diagnostic articles**, each titled `<description> (<GroupName>)`, with a
machine-readable index at `https://docs.swift.org/compiler/index/index.json`. The
compiler emits hyperlinks directly to them.

That deletes the stretch goal and replaces it with something better: a mechanical
first pass at the coverage audit.

**The load-bearing observation:** group tagging is incomplete. In one spike file,
`non_sendable_capture` and `actor_isolated_call_decl` carried groups;
`actor_isolated_non_self_reference`, `non_sendable_nominal`, `kind_declared_here`,
`add_globalactor_to_decl` and `shared_state_nonisolated_unsafe` carried none.

So the coverage classification becomes a three-way mechanical split:

| Class | Rule | Judgement needed |
|---|---|---|
| `documented` | has a group **and** that group has a rendered article | none |
| `grouped-undocumented` | has a group, no article | none |
| `ungrouped` | no group at all | none |

`ungrouped` is a zero-judgement proxy for "the compiler team has not written an
educational note for this." Hand-adjudication is then only needed for the migration
guide and ConcurrencyRecipes overlay on the top ~40, as SPEC §7 proposes, rather than
for the whole classification.

**This is a candidate M3 headline finding in its own right:** the fraction of
real-world data-race diagnostic occurrences that carry no diagnostic group and
therefore no official explanation. Nobody has published that number.

### A6 — Toolchain matrix

**Amends:** §4.2, §5.4 example.

The SPEC's examples (6.1 / 6.2 / 6.3-dev) predate two releases.

| Column | Version | Note |
|---|---|---|
| n−3 | 6.1 | oldest with `-print-diagnostic-groups` |
| n−2 | 6.2 | |
| n−1 | 6.3 | SPI's current top row |
| n | 6.4 | ships in Xcode 27; Xcode 27 is beta as of writing |
| nightly | 6.5-dev | highest-value column per §4.2 |

Swift 6.0 is **dropped**: no `-print-diagnostic-groups`, so its records could not
carry the secondary key and A5's coverage split would be undefined for that column.

### A7 — M1's exit condition is restated

**Amends:** §8 M1 exit.

"Re-running on the same inputs produces byte-identical diagnostic sets" is not
achievable. Observed output already contains absolute paths, build-directory paths,
and non-deterministic job ordering; macro plugin loading and parallel scheduling vary
run to run.

**Restated exit condition:** re-running on identical inputs produces a **set-identical
normalised diagnostic multiset** — the sorted multiset of
`(diagnostic_id, repo_relative_path, line, col, severity)` is equal. Same rigour,
correct level of abstraction.

### A8 — Notes are first-class but excluded from ranking

**Amends:** §5.3.

Compiler notes carry their own identifiers and are the compiler's *proposed remedies*
(`add_globalactor_to_decl`, `shared_state_nonisolated_unsafe`,
`shared_state_make_immutable`). "Which fix does the compiler suggest, and how often"
is one of the more interesting things this dataset can answer, and it destroys a naive
frequency count if merged into the primary distribution.

Schema additions: every record gets `severity` ∈ {`error`, `warning`, `note`} and
notes get `parent_id` linking to the diagnostic they attach to. Notes are excluded
from `total_occurrences`, from both coverage denominators, and from the ranking.
They are aggregated separately as a *remedy distribution*.

### A9 — Record the bench coupling, as one line

**Amends:** §9 (open questions).

Add, without adding scope:

> 6. **Does the multi-SHA corpus support mining fix diffs as agent-evaluation tasks?**
>    Recorded so the option survives; not investigated before M3.

Rationale is in the second transcript: the census is upstream of `swift-bench` in
three channels — task selection (the residual ranking is the correct difficulty
signal), task generation (§9.4's mined fix diffs are benchmark tasks whose
`FAIL_TO_PASS` is the compiler, needing no test suite), and grading (the diagnostic-ID
machinery is the deterministic grader). Nothing flows the other way.

**The stated risk, which this roadmap exists partly to resist:** the census is built
to be finishable and the bench is built to be ongoing. Same repo or same mental slot
and the bench eats the census. Separate repos. The census reaches M3 first.

### A10 — Escape-hatch census (adopted)

**Adds to:** §4 architecture, §5.3 schema, M1, M2, M3. Promoted from §8 on explicit
decision, 2026-09-05.

Swift Package Index states the blind spot in its own FAQ: it cannot tell whether zero
diagnostics means genuinely race-free code or suppression via techniques like
`@unchecked Sendable`. That is a published, unanswered question about the exact corpus
this project measures, and answering it costs one SwiftSyntax pass over source that is
already checked out.

**The finding this exists to produce** is not the raw count. It is the cross-tab:
**suppression rate against SPI-reported diagnostic count.** Does "clean" correlate with
"suppressed"? Nobody knows, and the ecosystem's canonical instrument says it cannot find
out.

**Taxonomy.** Counted separately, never merged into one "escape hatch" number, because
they mean materially different things:

| Construct | Syntactic position | What it means |
|---|---|---|
| `@unchecked Sendable` | conformance clause | author asserts safety the compiler cannot verify |
| `nonisolated(unsafe)` | declaration modifier | author asserts external synchronisation |
| `@preconcurrency` on `import` | import attribute | staging a not-yet-audited dependency — **weakest signal**, often correct |
| `@preconcurrency` on a conformance or declaration | attribute | narrower, deliberate suppression |
| `assumeIsolated` / `MainActor.assumeIsolated` | call expression | converts a static guarantee into a runtime trap |
| `.unsafeFlags([...])` in `Package.swift` | manifest | build-level suppression (`-suppress-warnings`, concurrency flag overrides) |

The `@preconcurrency` split is load-bearing. Lumping `@preconcurrency import` together
with a `@preconcurrency` conformance would inflate the headline number with something
that is usually good practice.

**Why SwiftSyntax and not a regex:** these constructs appear in comments, string
literals and documentation. A regex census would be wrong in a direction that flatters
the finding, which is the worst direction.

**Denominators.** Raw counts are uninterpretable. Report all three:

- packages containing ≥1 occurrence, over corpus size (breadth)
- occurrences per 1,000 non-comment source lines (intensity)
- the cross-tab against diagnostic count (the actual finding)

**Implementation.** A new `SuppressionScan` module under `tools/Sources/`. This is a
fifth module where SPEC §11 lists four, justified by dependency isolation rather than
taxonomy: it needs `swift-syntax`, and `CensusCore` should not inherit that dependency.
Pin `swift-syntax` to the newest toolchain in the matrix. SwiftSyntax is error-tolerant
and will not crash on newer syntax than it knows, but it *will* misparse it — so the
scan records a per-file parse-confidence flag and the report states what fraction of
the corpus parsed cleanly.

**Cost:** ~1 day. **Compiles nothing**, so it cannot fail a matrix cell and can run
independently of the build matrix entirely.

### A11 — Test targets are out of scope

**Amends:** ROADMAP §7 F5, which is hereby decided rather than open.

`swift build` excludes test targets and the runner does **not** pass `--build-tests`.

Three reasons, in order of weight:

1. **Comparability to SPI.** §4.2 makes matching SPI's measurement an explicit goal, and
   their published figures come from a plain build. Diverging here would make every
   comparison to their numbers unsound.
2. **Test code is not shipped code.** A diagnostic in a test target is not a property
   consumers of the package encounter.
3. **Test targets have systematically different concurrency hygiene** — XCTest legacy
   patterns, `@MainActor` test classes, Swift Testing migration artifacts. Including them
   would skew the distribution toward test-specific patterns and contaminate the
   ecosystem claim.

**On whether test-target data is worth publishing:** yes, but as a *separate* study with
its own denominator, not folded into the primary distribution. Concurrency in test code
is a genuinely distinct population and mixing the two produces a number that describes
neither. Not v1 scope.

**One verification task for M0**, because reason 1 is the load-bearing one: confirm what
SPI's `xcodebuild build -scheme <pkg>-Package` invocation actually compiles on Apple
platforms. An auto-generated Package scheme may include test targets in its build action.
If it does, reason 1 inverts and this amendment is revisited. Do not assume.

### A12 — macOS is the canonical platform; Linux is the canonical reproduction path

**Amends:** ROADMAP §7 F6, which is hereby decided. Adds a constraint A6 did not state.

**macOS (`macos-spm`) is canonical** for the headline distribution, per SPEC §4.2's
"primary" designation. It admits packages requiring Apple SDKs, and the concurrency
patterns that matter most to this project's audience — `@MainActor` propagation through
UI-adjacent code — exist only there. A Linux-canonical census would systematically
under-represent the interesting half of the problem.

**But Linux is published alongside as the reproduction path, and this is not optional.**
The project's origin framing is a knowledge commons whose value comes from being
auditable rather than trusted. A macOS-only result is auditable only by people who own
Apple hardware, which is a real barrier to exactly the property the project exists to
demonstrate. Linux is also containerisable, which is how F3's security requirement gets
satisfied cheaply, and it is where nightly toolchains are least painful.

So: macOS produces the headline number; the Linux column ships with it, and the README
states the reproduction command for the Linux-buildable subset.

**The constraint A6 missed: the canonical column must be GA at publication time.**
Xcode 27 / Swift 6.4 is currently beta 6. A beta toolchain must not be the canonical
column of a published measurement — its diagnostics can change before release, which
would invalidate the headline finding after publication with no way to correct the
record cleanly. Canonical is the newest **released** toolchain at M3 (6.3 today, 6.4 if
Xcode 27 has shipped by then). Beta and nightly remain in the matrix as forward-looking
columns, clearly labelled, and are never the headline.

---

---

## 2. Revised architecture

Unchanged from SPEC §4 except where A1–A8 apply. The delta:

```
SPI /builds pages ─┐
                   ├─> corpus selection ─> corpus/packages.yaml (SHA-pinned, stratified)
SPI chart JSON ────┘                              │
                                                  v
                                    matrix runner (5 toolchains x strict-complete)
                                                  │  stderr, llvm style,
                                                  │  -debug-diagnostic-names
                                                  v
                                    DiagParse  (ANSI + OSC-8 strip, dedup)
                                                  │
docs.swift.org index.json ──> coverage classifier │
                                                  v
corpus checkouts ──> SuppressionScan ───────────> CensusCore ─> census.json ─> report.md
   (no compilation)                                                └─> suppression.json
```

`DiagParse` shrinks from "compiler-archaeology subsystem" to "line parser with
careful escape-sequence handling." That is the single largest change this roadmap
makes to the workload.

**Implementation language: Swift**, per SPEC §11. Acknowledged cost: M0–M2 is text,
YAML, JSON, HTTP and process orchestration, all of which Swift does more slowly than
the alternative, and the tool bootstraps on the toolchain it measures. Accepted
because `EntryVerify` must be Swift, the tool must run on Linux and macOS, it
dogfoods, and this is a Swift-ecosystem artifact whose credibility is Swift-ecosystem
credibility. **The M0 spike is exempt** — write it in whatever is fastest and throw
it away.

---

## 3. Milestones

### M0 — Capture spike

Deliberately falsification-shaped. M0's job is to break A1–A4 if they are breakable.

1. Install the matrix toolchains (6.1, 6.2, 6.3, 6.4, nightly).
2. For each toolchain, confirm `-debug-diagnostic-names` and `-print-diagnostic-groups`
   pass through `swift build -Xswiftc` and produce identical identifier text for the
   same source. **A1 dies here if identifiers differ across toolchains for the same
   construct.**
3. Confirm the A2 asymmetry on a real package, not a spike file. Record diagnostic
   counts under `strict-complete` vs `swift6` for one `S-emit` candidate.
4. Test `-show-diagnostics-after-fatal` and build-system continue-after-errors for
   recovery of censored diagnostics.
5. Inspect a `.dia` from the `swiftbuild` output tree. Does it preserve the
   identifier? Decide route 2's fate.
6. Characterise SPI log truncation: fetch ~10 `/builds/<uuid>` pages across successful
   and failing builds, measure log length, and determine whether compile-phase
   diagnostics survive. (One sample was a 192KB tail with zero `swift-frontend` lines.)
   This does not gate M0 — it gates whether SPI ingestion is ever viable as a future
   stratum.
7. Confirm what SPI's `xcodebuild build -scheme <pkg>-Package` actually compiles on
   Apple platforms — specifically whether test targets are included (A11 reason 1
   depends on this).
8. Write the parser: ANSI strip, OSC-8 strip, dedup, emit JSON.

**Exit:** `samples/m0.json` committed, containing parsed, deduplicated, ID-keyed
diagnostics from one real package on one toolchain; plus `docs/decisions/0001-capture-route.md`
recording the route decision and the answers to items 2–6.

### M1 — Corpus and matrix runner

1. Build the corpus selector: pull SPI package list and per-package data-race counts,
   sample the four strata of A3, resolve each to a pinned 40-char SHA, and
   generate a vendored `Package.resolved` per entry (see §7 F1).
2. `corpus/packages.yaml` committed with `stratum` and `spi_error_count_at_selection`.
3. Runner over strata × 5 toolchains, `strict-complete` only, plus the `swift6`
   overlay on `S-anchor` alone.
4. Raw per-run output committed under `runs/<date>/`.
5. `SuppressionScan` over every corpus checkout (A10). No compilation, so it runs
   independently of the matrix and cannot block it.

**Exit (per A7):** one full run over all three strata, results committed, and a
re-run producing a set-identical normalised diagnostic multiset.

**Compute note:** SPEC §4.2's budget assumed ~30 packages × 5 toolchains on one Mac
mini overnight. ~65 packages × 5 toolchains is a wider matrix; run Linux-capable
packages on Linux runners and reserve macOS for the Apple-SDK-only set, as specced.

### M2 — Normalisation, coverage classification, ranking

1. Aggregation into `census.json` per §5.3 plus A8's `severity` / `parent_id`.
2. Coverage classifier per A5: fetch `docs.swift.org/compiler/index/index.json`,
   join on group name, emit the three-way split.
3. Hand-adjudicate the top 40 against the migration guide and ConcurrencyRecipes;
   record in `corpus/coverage-audit.yaml` per SPEC §7.
4. Ranked report: primary key **distinct packages affected**, secondary occurrences,
   per SPEC §7.
5. Report the `ungrouped` fraction as a first-class figure.
6. Aggregate `suppression.json` per A10: breadth, intensity, and the cross-tab of
   suppression rate against diagnostic count.

**Exit:** ranked table of diagnostic IDs by distinct-packages-affected, top 10 spot-checked
against raw build logs, all three coverage figures computed
(`occurrence_coverage`, `package_coverage`, `residual`), and the suppression cross-tab
produced with its parse-confidence figure stated.

### M3 — Publish the finding ← SHIP LINE

Write up: concentration of the distribution, what dominates, how it shifts across five
toolchains, what nightly predicts, and the ungrouped/undocumented fraction.

Two findings are worth naming as likely headlines, subject to the data:

- The fraction of real-world data-race diagnostics carrying **no diagnostic group and
  therefore no official explanation** (A5).
- **Whether "clean" means clean or means suppressed** (A10) — the question SPI's FAQ
  states it cannot answer about its own headline figure.
- The fact that the ecosystem's only public data-race measurement **stopped updating
  at Swift 6.1 in May 2025**, three toolchains ago. This strengthens SPEC §1's problem
  statement and improves the odds on SPEC §8's opportunistic upstream contribution.

**Exit:** published on ajscanlan.dev, repo public, README pointing at `census.json`.
**Project is complete here.**

### M4 / M5 — unchanged from SPEC §8, and still optional

Gated on SPEC §9.4's four-way fork, evaluated against M2's actual distribution.

---

## 4. Decision gates

| Gate | When | Question | Consequence |
|---|---|---|---|
| G0 | M0 item 2 | Do identifiers agree across toolchains? | No → A1 reverts, SPEC §5.2's `.def` matcher gets built, M2 roughly triples |
| G1 | M0 item 5 | Does `.dia` carry the identifier? | Yes → route 2 available for M1 hardening. No → delete routes 1 and 2 from the SPEC |
| G2 | M1 exit | Did `S-emit` actually emit? | Near-zero → the corpus selector is broken or the ecosystem moved; investigate before M2 |
| G3 | M2 exit | Which of SPEC §9.4's four shapes? | Determines whether M4 happens at all, and in hand-authored or mined form |

G3 is pre-registered in SPEC §9.4 with a committed response per shape. Do not
re-litigate it after seeing the data — that is the entire point of writing it down first.

---

## 5. Risks

| Risk | Severity | Mitigation |
|---|---|---|
| `-debug-diagnostic-names` is undocumented and unguaranteed | High | Store rendered message alongside every ID; `.def` matcher stays a documented contingency (A1) |
| SPI selection signal is 16 months stale | Medium | `S-control` stratum bounds it; limitation stated in the report (A3) |
| Xcode 27 / Swift 6.4 is beta; behaviour may shift before GA | Medium | Pin exact build numbers in every run record; treat 6.4 as a provisional column |
| Corpus still comes back near-empty | Medium | G2 catches it at M1 exit, before M2 effort is spent |
| Nightly toolchain flakiness blocks a weekly run | Low | Nightly column is allowed to fail without failing the run |
| `swift-syntax` misparses newer syntax than its pinned version | Low | A10 records per-file parse confidence; report states the clean-parse fraction |
| The bench eats the census | **High** | Separate repos; A9 caps the coupling at one recorded question; M3 first |

---

## 6. Explicitly not in scope before M3

Restating SPEC §2, plus what this roadmap adds:

- No SPI log ingestion. Characterised in M0 item 6, recorded, not built.
- No `.def` parser unless G0 fails.
- No entries, no `llms.txt`, no MCP server.
- No `swift-bench` work of any kind.
- No non-concurrency diagnostic families.

Per SPEC §12: an item moved to "later" is scope this project is carrying. The list
above is carried deliberately and is short on purpose.

---

## 7. Implementation footguns

Ranked by how likely each is to make the project **publish a wrong number**, which is
the only failure mode that matters for an instrument. F1–F3 are correctness or safety
issues and must be resolved before M1 completes. F4–F6 are consistency decisions that
must be made once, written down, and not revisited per-package.

### F1 — SHA-pinning a package does not pin its dependencies

**Breaks:** SPEC P7, and M1's exit condition (A7).

Library packages conventionally `.gitignore` `Package.resolved`. A pinned package SHA
therefore fixes only the manifest, not the graph: `from: "1.0.0"` resolves to whatever
is newest on the day the runner executes. Re-run in three months and dependency
versions differ, diagnostics differ, and the normalised multiset comparison fails for
reasons that have nothing to do with the toolchain. Every cross-run frequency
comparison in the census silently becomes invalid.

**Required:**

1. Corpus baselining generates and commits a `Package.resolved` per entry, alongside
   the SHA, under `corpus/resolved/<package-id>.resolved`.
2. The runner copies it into the checkout before building.
3. Every build enforces it:

   ```bash
   swift build --force-resolved-versions \
     -Xswiftc -strict-concurrency=complete \
     -Xswiftc -swift-version -Xswiftc 5 \
     -Xswiftc -debug-diagnostic-names \
     -Xswiftc -print-diagnostic-groups \
     -Xswiftc -no-color-diagnostics \
     -Xswiftc -diagnostic-style=llvm
   ```

   (`--force-resolved-versions`, aliased `--only-use-versions-from-resolved-file`, is
   present in current SwiftPM.)

Bumping a vendored `Package.resolved` is the same deliberate, documented operation as
bumping a corpus SHA, per SPEC §12. Never a drive-by update.

### F2 — Dependency diagnostics will be attributed to the wrong package

**Breaks:** `distinct_packages`, which SPEC §7 makes the *primary* ranking key.

Building package P builds its whole dependency graph. A diagnostic emitted in
`.build/checkouts/swift-foo/Sources/...` belongs to `swift-foo`, not to P. Counted
naively, one upstream diagnostic is credited once per dependent package and inflates
the headline ranking key directly.

**Required:** attribute every diagnostic by source path. Only diagnostics whose file
resolves under the package's own source root count toward that package. Diagnostics
from `.build/checkouts/` are either dropped or recorded in a separate
`transitive` bucket — never merged into the primary distribution.

Related, and worth a line in the M3 write-up: some fraction of ecosystem-wide
diagnostics are *one* upstream defect observed many times. The corpus cannot fully
resolve this, but path-based attribution is the minimum honest treatment.

### F3 — Building the corpus executes third-party code

**Not a correctness issue. A security one.**

`swift build` runs each package's SwiftPM prebuild/build plugins and macro
implementations. A ~65-package corpus is ~65 third-party build-time code execution
surfaces, and the runner will need `-skipMacroValidation` (as SPI's own invocation
does) which suppresses the macro trust prompt — so this code runs unprompted.

**Required decision, recorded in an ADR before M1:**

- Linux strata run containerised. No exceptions.
- macOS strata do not run on a machine holding signing keys or personal data. A
  dedicated machine, a VM, or a runner.
- Corpus SHAs are pinned (P7), which bounds the surface to code reviewable at a fixed
  revision. That is the mitigation, and it is another argument for never bumping SHAs
  casually.

This is the same threat model as "never open an untrusted repo with an agent running,"
scaled to sixty-five repositories.

### F4 — `.build` state contaminates across toolchains

Module caches and `.swiftmodule` files are toolchain-specific. Reusing a build tree
across matrix cells produces phantom diagnostics from stale modules, or misses
diagnostics entirely.

**Required:** every `(package, toolchain, mode)` cell builds in a clean tree.

**Consequence for the budget:** no incremental reuse anywhere in the matrix. SPEC
§4.2's overnight estimate assumed ~30 packages; at ~65 packages × 5 toolchains with
cold builds throughout, measure one full cell before extrapolating.

### F5 — Decide whether test targets are in scope, once

`swift build` excludes test targets; `--build-tests` includes them. Test code is
concurrency-violation-rich and arguably less representative of shipped behaviour.

Either choice is defensible. **Inconsistency is not**, and neither is deciding
per-package. Record the choice in the run manifest so the number is interpretable.

**Decided (A11): out.** No `--build-tests`. M0 item 7 verifies the SPI-comparability
premise this rests on.

### F6 — Cross-platform counts are not summable

`#if canImport(Darwin)` and friends mean a macOS build and a Linux build of the same
package compile different source. Summing occurrences across platforms measures
nothing coherent.

**Required:** aggregate per-platform. If a single headline distribution is needed for
M3, nominate one platform as canonical and say so.

**Decided (A12): macOS is canonical; Linux ships alongside as the reproduction path;
the canonical toolchain column must be GA, never a beta.**

### F7 — Pin the invocation, not just the corpus

P7 pins source. It does not pin the *measurement*. Flags, resolved target triples, SDK
version and Xcode build number all move independently and all change diagnostic output
— the observed default deployment target came from the package manifest
(`-target arm64-apple-macos12.0`), not from the runner.

**Required:** every run record stores the fully resolved frontend invocation, plus
toolchain version string, Xcode build number where applicable, and target triple.
Cheap insurance against a category of unreproducibility that is otherwise invisible.

---

## 8. Proposed but not adopted

Recorded here so the option is not silently lost, and so no agent adds it on its own
initiative. Neither is scope until explicitly accepted.

**~~P1 — Escape-hatch census.~~** **Adopted 2026-09-05. Now A10.**

**P2 — Nothing else.** Additions to this list require the same justification as
additions to scope. Per SPEC §12: prefer deleting scope to deferring it, and a list
like this is a place deferred scope hides.
