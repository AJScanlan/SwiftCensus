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
- **Results are never reinterpreted after they are seen.** Gates and rules are pre-registered in an ADR
  before the runs they judge. A failed check stays on record as failed; a rule changed after a result
  is tested on fresh runs, never re-scored on the data that failed it.
- **A gate states its power before it is pre-registered:** the share of its population the gating
  measurement can observe (ADR 0009).
- **Freeze `tools/` before a matrix run, and get the code review before the freeze.** A fix after the
  freeze forces re-running both passes.
- **Check every number in a write-up against the run data before committing it.**

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

**A2 — AMENDED by ADR 0002. The primary mode is `strict-complete-v5`:
`-strict-concurrency=complete` with `-swift-version 5` FORCED for every package,
regardless of what it declares.** A package declaring `swift-tools-version: 6.x` is
already in Swift 6 mode, so declared-mode measurement is censored exactly for modern
packages — a bias correlated with migration status. Measured: 4 diagnostics under
tools-version 5.10, 1 under 6.0, 4 again with `-swift-version 5` forced.
`strict-complete-declared` is retained for SPI comparability only and is never a
frequency source. `swift6` as a separate mode is deleted.

**A3 — Corpus is stratified on evidence** (`S-emit` / `S-control` / `S-anchor` /
`S-byproduct`), not on package prestige. SPEC's T0+T1 is the 83–97%-clean stratum
and would have produced a near-empty census.

**A4 — SUPERSEDED by ADR 0001. Capture is route 2: serialized `.dia`.** `.dia` carries
the identifier and gives structured `level`, `location`, `category` and `categoryURL`.
Parser is `TSCUtility.SerializedDiagnostics` (public API). stderr is fallback only.

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
  -Xswiftc -swift-version -Xswiftc 5 \
  -Xswiftc -debug-diagnostic-names \
  -Xswiftc -print-diagnostic-groups \
  -Xswiftc -no-color-diagnostics \
  -Xswiftc -diagnostic-style=llvm
```

SwiftPM's default build system is `swiftbuild`; `native` (llbuild) is deprecated.
`.dia` files land under `.build/out/Intermediates.noindex/.../Objects-normal/<arch>/`.

## Parser must handle

Read `.dia` via `TSCUtility.SerializedDiagnostics`. Enumerate them from
`.build/out/Intermediates.noindex/**/Objects-normal/<arch>/*.dia` — one per frontend
job, so the **same diagnostic appears in several files**. Deduplicate on
`(diagnostic_id, relative_path, line, col, severity)`.

The identifier is a `[snake_case]` suffix on `text`; strip it into its own field.
Note-to-parent linkage is positional, not a field — notes follow their parent in
emission order.

Only if falling back to stderr: strip ANSI colour codes (injected even under
`-diagnostic-style=llvm`) and OSC-8 hyperlinks wrapping group names, and expect each
diagnostic printed twice under the `swift` style.

## Footgun checklist (ROADMAP §7)

- **F1** Vendor a `Package.resolved` per corpus entry and build with
  `--force-resolved-versions`. A package SHA does not pin its dependency graph.
- **F2** Attribute diagnostics by source path. `.build/checkouts/` diagnostics are
  never merged into the primary distribution — they inflate `distinct_packages`,
  the primary ranking key.
- **F3** Building the corpus executes third-party plugins and macros unprompted.
  Containerise Linux strata; keep macOS strata off any machine with signing keys.
- **F4** Clean build tree per `(package, toolchain, mode)` cell. No incremental reuse.
  **But share a per-toolchain `-module-cache-path` across cells** — SDK modules derive
  from toolchain+SDK, never package sources, and rebuilding them costs minutes per cell.
- **F5/F6** Decided: test targets out (A11); macOS canonical, Linux published
  alongside (A12). Record both in the run manifest. Never decided per-package.
- **F7** Record the fully resolved frontend invocation, toolchain string, Xcode
  build number and target triple in every run record.

## Running the matrix (learned the hard way)

- `xcrun swift build --package-path tools` / `xcrun swift test --package-path tools`, never bare `swift`: a swiftly
  default on PATH cannot build against the Xcode 27 SDK. Test output has four "Test run with N tests" lines (one per
  target); the total is their sum, not the last line.
- Runs use `tools/.build/release/census`. Run `scripts/matrix-preflight.sh linux|macos <freeze-commit>`
  before every run; it rebuilds the release binary and checks the pinned images, guest digest and tree.
- `census run` resumes when the same command is re-issued (cells with `cell.json` are skipped). Never
  `--force`. Retry one cell by deleting its directory.
- Docker Desktop and the macOS guest do not fit in 16 GiB together: quit Docker before any macOS run.
  A Linux pass takes ~75 min (335 cells); a macOS pass ~40 min of cells plus guest boot (69 cells; 2026-10-24).
- `docker image inspect swift:6.x` (bare tag) intermittently says "No such image" for a present image,
  and multi-argument `inspect` does too. Inspect one image per call; never trust a single lookup.
- SwiftPM does not relink an unchanged output, so mtime "is the binary stale?" checks give false
  positives. Rebuild instead.
- Swift parses `if a < b, c > d` as a generic argument list; parenthesise comparisons in conditions.
- A failed build's diagnostics depend on parallel scheduling and are not reproducible. They are never
  a frequency source (ADR 0010).
- Most packages do not build on Linux (41% of a uniform draw on 6.4). Never gate a stratum selected on
  macOS on a Linux result (ADR 0009).
- `work/` (source cache, ~7 GB) is gitignored. In a worktree, symlink it from the main checkout.

## Claude Code tooling (`.claude/`)

- The pre-freeze review is the `freeze-reviewer` agent, not a generic reviewer. Freeze only on `FREEZE: go`.
- Run the `numbers-auditor` agent on any write-up with numbers from runs before committing it.
- A hook block or ADR prompt is a project rule firing. Stop and ask; do not route around it (`sed -i`, redirects,
  another tool). The hooks catch mistakes; they are not a boundary.
- A commit message naming a blocked command trips the Bash guard: commit with `git commit -F <file>`.
- After editing a hook, run `.claude/hooks/test-hooks.sh` (exits 1 on any failing case).
- The agents exist only in sessions started where `.claude/agents/` is. Otherwise run a general-purpose agent with the
  agent file's body as its complete instructions (and `model: opus` for `freeze-reviewer`).
- Worktree-isolated sessions refuse compound shell (loops, `$(…)` around git/find, heredocs): use one plain command per
  call, literal values (read `work/<campaign>/FREEZE` once), Edit for appends, and scratch scripts for loops.

## Structure notes

- `DiagParse` carries golden-file tests from its first commit — it is the component
  most likely to be silently wrong, and silent wrongness reaches the published number.
- Commit raw log bytes (compressed) as well as parsed JSON, so the pipeline is
  re-derivable without recompute when the parser turns out to be wrong.
- Do not create `EntryVerify/` before M4. An empty module is deferred scope wearing
  a directory. `SuppressionScan/` is the fifth module and exists only so `swift-syntax`
  stays out of `CensusCore`'s dependency graph; pin it to the newest matrix toolchain.
- Record decisions as ADRs in `docs/decisions/`.
