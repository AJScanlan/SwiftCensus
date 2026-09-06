# ADR 0001 — Diagnostic capture route

**Status:** accepted
**Date:** 2026-09-06
**Milestone:** M0
**Supersedes:** ROADMAP A4, which recommended stderr parsing as final
**Environment:** Swift 6.4 (swiftlang-6.4.0.33.1), Xcode 27.0 beta 6 (27A5252f), macOS 27, arm64

## Context

SPEC §4.3 offers three capture routes and recommends building M0 on route 3 (stderr),
then hardening to route 1 (`.xcresult`) or route 2 (serialized `.dia`) once the shape
of the data is known. ROADMAP A4 inverted that, arguing route 3 was final *unless*
`.dia` could be shown to carry the stable diagnostic identifier, since structure is
worth less than the key.

M0 gate G1 asked exactly that question.

## Decision

**Route 2 — serialized diagnostics (`.dia`) — is the capture route.** Route 3 (stderr)
is retained only as a fallback for build configurations that emit no `.dia`.

## Evidence

`.dia` carries the identifier. `-debug-diagnostic-names` appends `[identifier]` to the
message text, and that text is serialized verbatim. Grepping a `.dia` produced from a
five-diagnostic source file found `non_sendable_capture`, `actor_isolated_call_decl`
and `add_globalactor_to_decl` present.

A parser was built and run end to end (M0 spike). `SerializedDiagnostics` in
`swift-tools-support-core` is **public API** — resolving the open question SPEC §4.3
raised — and `SerializedDiagnostics.Diagnostic` exposes:

| Field | Value for the census |
|---|---|
| `text` | message; carries `[identifier]` as a suffix |
| `level` | typed enum incl. `note` — satisfies A8's severity typing directly |
| `location` | structured filename/line/column — satisfies F2 attribution with no path parsing |
| `category` | the diagnostic group, as a **structured field** |
| `categoryURL` | the `docs.swift.org` educational-note URL, structured |
| `fixIts` | structured fix-its |

Parsed output for one diagnostic, verbatim from the spike:

```json
{
  "category": "ActorIsolatedCall",
  "categoryURL": "https://docs.swift.org/compiler/documentation/diagnostics/actor-isolated-call",
  "col": 18, "file": "Sources/Spike/Spike.swift", "line": 13,
  "fixIts": 0,
  "id": "actor_isolated_call_decl",
  "level": "error",
  "text": "call to main actor-isolated global function 'onMain()' in a synchronous nonisolated context"
}
```

## Consequences

**Deleted work.** ROADMAP A4's stderr parser requirements are no longer on the critical
path: no ANSI-code stripping, no OSC-8 hyperlink unwrapping, and no double-emission
from the `swift` diagnostic renderer. Those artifacts are properties of terminal
rendering and do not exist in the serialized format.

**A5 gets simpler.** `categoryURL` is emitted by the compiler per diagnostic, so the
"is this documented" test does not require joining against
`docs.swift.org/compiler/index/index.json`. **Open for M2:** whether a group that has
no rendered article yields a non-nil `category` with a nil `categoryURL`. If it does,
A5's three-way split is computable from the `.dia` alone. Verify before relying on it;
retain the index join as the fallback.

**A8 gets simpler.** `level` distinguishes `note` natively. Note-to-parent linkage is
*not* an explicit field — notes follow their parent in emission order — so `parent_id`
must still be reconstructed positionally. Test this against a diagnostic with multiple
notes before trusting it.

**New dependency.** `swift-tools-support-core`, for `TSCUtility.SerializedDiagnostics`.
Pin it. It is a `swiftlang` package that SwiftPM itself consumes, but parts of TSC are
being absorbed elsewhere over time, so treat availability as a tracked risk rather than
a given.

**New runner obligation.** `.dia` files must be enumerated from the build tree rather
than read from a pipe. Under the `swiftbuild` build system they land at
`.build/out/Intermediates.noindex/<Module>.build/<Config>/<Target>.build/Objects-normal/<arch>/*.dia`,
one per frontend job — including `-primary-emit-module.dia` and `-dependency-scan.dia`.
The same diagnostic still appears in more than one file, so **deduplication on
`(diagnostic_id, relative_path, line, col, severity)` remains required.**

**Unchanged.** A1 stands: the identifier still comes from `-debug-diagnostic-names` and
is still embedded in message text rather than exposed as a structured field. The
canonical invocation keeps that flag. `-no-color-diagnostics` and
`-diagnostic-style=llvm` become optional, but are retained so the stderr fallback stays
parseable.

## Related M0 findings

**Censored diagnostics are not recoverable (A2 confirmed and strengthened).** On the
same source, `-swift-version 6` emitted 2 diagnostics against 3 for Swift 5 +
`-strict-concurrency=complete`, losing `non_sendable_capture` and
`non_sendable_nominal`. `-show-diagnostics-after-fatal` recovered neither. The loss
occurs *within a single frontend invocation*, not merely at build-halt granularity, so
A2's demotion of `swift6` from a frequency source is more strongly justified than when
written.

**A11 confirmed, not assumed.** SPI's macOS (SPM) build command is
`env DEVELOPER_DIR=... xcrun swift build --arch arm64` — plain `swift build`, no
`--build-tests`, and no test-target compilation in the log. A11's comparability premise
holds for `macos-spm`, which A12 makes canonical.

**SPI logs are tail-truncated (SPEC §9.2).** A 115.8k-character `swift build` log
survived intact from its first line; a 192.1k-character `xcodebuild` log for the same
package began mid-build with the compile phase already cut and carried no truncation
notice. The cap sits between those figures. Verbose `xcodebuild` logs lose their
diagnostics; `swift build` logs mostly survive. Recorded for a possible future SPI
ingestion stratum; not in scope.

**Open, and it affects A3.** The `Swift 6 data race errors: N` figure shown on a build
page comes from a build command with no `-strict-concurrency=complete` flag. It may
therefore report the package's declared-language-mode result rather than the
strict-complete measurement the census performs. If so, selecting `S-emit` on that
number selects on a different measurement than the census makes. Resolve during M1
corpus selection.
