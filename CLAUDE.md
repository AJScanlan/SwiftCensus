# CLAUDE.md — swift-diagnostic-census

An instrument that compiles a pinned corpus of Swift packages across a toolchain
matrix with strict concurrency checking, captures every diagnostic, keys it to a
stable compiler-internal identifier, and publishes the frequency distribution.

**The measurement is the product.** An entry corpus is an optional downstream
artifact, not the goal.

## Read order

1. `SPEC.md` — intent. Authoritative on §2 (non-goals) and §3 (principles).
2. `ROADMAP.md` — execution. §1 amends the SPEC with verified evidence; §7 lists
   footguns. **Where the two disagree, ROADMAP §1 wins and says why.**
3. `docs/decisions/` — ADRs. Check before re-deciding anything.

## Hard rules

- **M3 is the ship line.** M0–M3 produce a working instrument and a published
  finding with zero entries written. M4 and M5 are optional.
- **Never advance a milestone whose predecessor's exit condition is unmet.**
- **`expect` fields are assertions.** A failing check is investigated to find out
  whether the compiler changed. It is never relaxed to make CI green.
- **Corpus SHAs and vendored `Package.resolved` files are pinned deliberately.**
  Bumping either invalidates cross-run comparability. It is a documented operation
  with a fresh baseline run, never a drive-by update.
- **Prefer deleting scope to deferring it.** An item moved to "later" is scope this
  project is carrying.
- **No unreviewed generated prose** in `entries/*/NOTES.md`. Drafting is fine.

## Do not propose these — they were considered and rejected

No submission flow, accounts, moderation, or reputation. No dynamic web app —
static output only. No non-concurrency diagnostic families in v1. Not a tutorial
site. Not a fork of Swift Package Index. Not a replacement for the official
migration guide — if the guide covers something adequately, link out instead of
writing an entry.

## Design principles (decisions, not suggestions)

- **P1 Measure, don't curate.** Entry selection comes from the empirical ranking,
  never from "things the author hit." This applies to corpus selection too.
- **P2 The instrument ships before the corpus.**
- **P3 Every claim is a CI-failable assertion.**
- **P4/P5 Reuse the compiler's own harness and repros** (`-typecheck -verify`,
  `swiftlang/swift/test/Concurrency/`). Do not write a bespoke assertion framework.
- **P6 Stable IDs over message text.**
- **P7 Pinned corpus.** "Latest" is forbidden in the manifest.
- **P8 Coverage is reported as a number.**

## Amendments you must not undo (ROADMAP §1)

**A1 — Stable IDs come from `-debug-diagnostic-names`, not from `Diagnostics*.def`.**
The compiler prints the internal identifier inline. **Do not build a `.def` fetcher
or a format-string→regex matcher.** SPEC §5.2's strategy is a documented
contingency, live only if ROADMAP gate G0 fails. Every record stores the rendered
message alongside the ID as the fallback.

**A2 — `strict-complete` is the only frequency source.** Under `-swift-version 6`
these diagnostics are errors, the frontend halts, and downstream diagnostics are
never emitted. `swift6`-mode counts are censored, not measured. They are tagged
`censored: true` and excluded from all ranking.

**A3 — Corpus is stratified on evidence** (`S-emit` / `S-control` / `S-anchor` /
`S-byproduct`), not on package prestige. SPEC's T0+T1 is the 83–97%-clean stratum
and would have produced a near-empty census.

**A4 — stderr capture (route 3) is final unless `.dia` is shown to carry the ID.**

**A5 — Coverage classification is mechanical:** `documented` / `grouped-undocumented`
/ `ungrouped`, joined against `docs.swift.org/compiler/index/index.json` (79
articles). "No group" is a zero-judgement proxy for "no official explanation."

**A6** matrix is 6.1 / 6.2 / 6.3 / 6.4 / nightly. 6.0 is dropped — no
`-print-diagnostic-groups`.

**A7** M1 exit is *set-identical after normalisation*, never byte-identical.

**A8** Notes carry `parent_id`, are excluded from ranking, and aggregate separately
as a remedy distribution.

**A9** The `swift-bench` coupling is one recorded question in SPEC §9. It is not
scope. Separate repo. The census reaches M3 first.

**A10 — Escape-hatch census is in scope.** A `SuppressionScan` module (SwiftSyntax,
no compilation) counts `@unchecked Sendable`, `nonisolated(unsafe)`, `@preconcurrency`
(import vs conformance/decl counted **separately**), `assumeIsolated`, and
`.unsafeFlags` in manifests. Never a regex — these appear in comments and string
literals. The finding is the cross-tab of suppression rate against diagnostic count,
not the raw count.

**A11 — Test targets are out.** No `--build-tests`. Primarily for SPI comparability.

**A12 — macOS is canonical; Linux ships alongside as the reproduction path.** The
canonical toolchain column must be **GA, never a beta** — a beta's diagnostics can
change after you publish.

## Canonical build invocation

```bash
swift build --force-resolved-versions \
  -Xswiftc -strict-concurrency=complete \
  -Xswiftc -debug-diagnostic-names \
  -Xswiftc -print-diagnostic-groups \
  -Xswiftc -no-color-diagnostics \
  -Xswiftc -diagnostic-style=llvm
```

SwiftPM's default build system is `swiftbuild`; `native` (llbuild) is deprecated.
`.dia` files land under `.build/out/Intermediates.noindex/.../Objects-normal/<arch>/`.

## Parser must handle

ANSI colour codes (injected even with `-diagnostic-style=llvm`); OSC-8 hyperlinks
wrapping group names; duplicate emission (once per frontend job, twice under the
`swift` style). Deduplicate on
`(diagnostic_id, relative_path, line, col, severity)`.

## Footgun checklist (ROADMAP §7)

- **F1** Vendor a `Package.resolved` per corpus entry and build with
  `--force-resolved-versions`. A package SHA does not pin its dependency graph.
- **F2** Attribute diagnostics by source path. `.build/checkouts/` diagnostics are
  never merged into the primary distribution — they inflate `distinct_packages`,
  the primary ranking key.
- **F3** Building the corpus executes third-party plugins and macros unprompted.
  Containerise Linux strata; keep macOS strata off any machine with signing keys.
- **F4** Clean build tree per `(package, toolchain, mode)` cell. No incremental reuse.
- **F5/F6** Decided: test targets out (A11); macOS canonical, Linux published
  alongside (A12). Record both in the run manifest. Never decided per-package.
- **F7** Record the fully resolved frontend invocation, toolchain string, Xcode
  build number and target triple in every run record.

## Structure notes

- `DiagParse` carries golden-file tests from its first commit — it is the component
  most likely to be silently wrong, and silent wrongness reaches the published number.
- Commit raw log bytes (compressed) as well as parsed JSON, so the pipeline is
  re-derivable without recompute when the parser turns out to be wrong.
- Do not create `EntryVerify/` before M4. An empty module is deferred scope wearing
  a directory. `SuppressionScan/` is the fifth module and exists only so `swift-syntax`
  stays out of `CensusCore`'s dependency graph; pin it to the newest matrix toolchain.
- Record decisions as ADRs in `docs/decisions/`.
