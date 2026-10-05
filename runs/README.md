# runs/

Raw per-run output (ROADMAP M1 item 4). Layout per cell:
`runs/<run-id>/<toolchain>/<mode>/<package-slug>/{cell.json, diagnostics.json, build.log.gz, dia.tar.gz}`.
`run.json` records the tools commit, corpus hash, Docker version and image IDs (F7).

| Run | What it is |
|---|---|
| `2026-10-04` | First full Linux run: 5 toolchains × 33 runnable packages, 185 cells. |
| `2026-10-04-rerun` | Identical inputs, re-run for the A7 check. |

`census compare runs/2026-10-04 runs/2026-10-04-rerun` → **SET-IDENTICAL** over all 185 cells
(155 cells with diagnostics compared as multisets; 30 whose equal outcomes carry none).

## What these runs are not

- **Not the M1 exit.** `S-emit` is empty (waiting on the owner's SPI data, ADR 0004 §4), and
  `S-byproduct` is macOS-only (LedgerKit imports `FoundationModels`; GRDB needs system SQLite
  headers) and the macOS column is blocked on F3. G2 (did `S-emit` emit?) cannot be evaluated.
- **Not a result.** Roughly 40% of `S-control` cells are `build_failed`, mostly Apple-only code on
  Linux, and 6.1's wrapped identifiers are undecided (ADR 0005). Do not read frequencies off these.
- **Linux aarch64 only**, one canonical column not yet chosen (ADR 0004 §2).

## Two instrument bugs this exposed (both fixed before these runs)

- Linux SwiftPM before 6.2 emits no `.dia` unless given `-serialize-diagnostics`; without it 6.1
  cells silently reported zero diagnostics.
- At 3 GB per container, swift-syntax-heavy packages were OOM-killed mid-build, so two runs on
  identical inputs disagreed on three cells. These runs use one cell at a time with 7 GB.
