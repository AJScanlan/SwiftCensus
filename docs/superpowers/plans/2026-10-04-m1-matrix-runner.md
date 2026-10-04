# M1 — Corpus and Matrix Runner Implementation Plan

**Goal:** Meet the M1 exit condition (ROADMAP A7): one full run over all strata, results
committed under `runs/<date>/`, and a re-run producing a set-identical normalised
diagnostic multiset.

**Architecture:** A Swift package under `tools/` with four targets — `CensusCore`
(schemas, dedup, normalisation), `DiagParse` (`.dia` via `TSCUtility.SerializedDiagnostics`,
ADR 0001), `SuppressionScan` (SwiftSyntax, A10), and a `census` executable (corpus
selection, matrix runner, run comparison). The runner drives one clean `docker run` per
`(package, toolchain, mode)` cell (F3, F4); parsing happens on the host from the mounted
build tree.

**Spec:** `SPEC.md`, `ROADMAP.md` §1 (A1–A12), §3 M1, §7 (F1–F7); ADRs 0001–0003.

## Global Constraints

- Canonical invocation is fixed by CLAUDE.md; mode `strict-complete-v5` only (ADR 0002).
- Corpus manifest pins 40-char SHAs; "latest" forbidden (P7). `Package.resolved` vendored per entry under `corpus/resolved/<id>.resolved`, builds use `--force-resolved-versions` (F1).
- Clean tree per cell; shared per-toolchain `-module-cache-path` (F4).
- Diagnostics attributed by source path; `.build/checkouts/` never merged into the primary distribution (F2).
- Dedup key `(diagnostic_id, relative_path, line, col, severity)`; notes attached positionally via `parent_id` (A8).
- Test targets out (A11). Linux in containers always (F3). macOS cells only on a machine without signing keys/personal data.
- Every run record stores resolved invocation, toolchain string, target triple, platform (F7).
- Raw `.dia`/logs committed compressed alongside parsed JSON.
- No `EntryVerify/`, no `.def` parser, no SPI log ingestion, no non-concurrency diagnostics.

## Review Focus

- Diagnostics in `.build/checkouts/**` must not count toward the package → test in Task 3.
- Same diagnostic in several `.dia` files must dedup to one → test in Task 2.
- Notes must not inflate counts and must link to the right parent → Task 2.
- A package that fails to resolve/build must be recorded as a failed cell, not silently dropped → Task 5.
- `@preconcurrency import` and `@preconcurrency` conformance counted separately; constructs inside comments/strings not counted → Task 4.

---

### Task 1: Package scaffold + ADR for F3/matrix
Create `tools/Package.swift` (pin `swift-tools-support-core`, `swift-syntax`, `Yams`,
`swift-argument-parser`), empty-but-compiling targets, ADR 0004 (F3 isolation + Linux
matrix per ADR 0003 option A). Deliverable: `swift build` green in `tools/`.

### Task 2: DiagParse (golden-file tests first)
`DiagParse.parse(diaFiles:) -> [Record]`; dedup; `ParsedDiagnostic` with `id`,
`text`, `level`, `category`, `categoryURL`, `file`, `line`, `col`, `parentIndex`.
Golden fixtures: a real `.dia` generated from a probe source, expected JSON committed.

### Task 3: CensusCore attribution + normalisation
`Attribution.classify(file:, packageRoot:) -> primary | transitive | sdk | other`;
`NormalisedMultiset` (sorted tuples) with equality for A7; run-record schema
(`schema_version`, invocation, toolchain, triple, platform, cell status).

### Task 4: SuppressionScan
SwiftSyntax visitor counting the A10 taxonomy separately, per-file parse-confidence
flag, non-comment-line count, `.unsafeFlags` in manifests. Tests on fixtures including
comment/string decoys.

### Task 5: Runner (`census run`)
Per cell: fresh checkout copy at pinned SHA, vendored `Package.resolved`, `docker run`
with the canonical invocation, shared module cache volume per toolchain, collect
`**/*.dia`, parse, write `runs/<date>/<toolchain>/<package>/{cell.json,diagnostics.json,raw.tar.zst}`.
Failed cells recorded with reason.

### Task 6: Corpus selection (`census select`)
Strata per A3 → `corpus/packages.yaml`, `corpus/resolved/*`. **Selection signal for
`S-emit` is blocked — see below.**

### Task 7: Full run + re-run + compare (`census compare`)
Run everything, commit `runs/<date>/`, re-run, assert set-identical multiset (A7).
Check G2 (`S-emit` actually emits).

## Known blocker (found 2026-10-04)

`swiftpackageindex.com` serves a Cloudflare managed challenge to every non-browser
request (`cf-mitigated: challenge`, all paths including `/`, `/sitemap.xml`, badge and
data URLs). Without that data, A3's `spi_error_count_at_selection` cannot be obtained
mechanically, and passing the challenge would be circumventing an access control.
Tasks 1–5 and 7's tooling are unaffected. Task 6's `S-emit` stratum needs a decision.
