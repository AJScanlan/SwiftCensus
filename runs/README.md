# runs/

Raw per-run output (ROADMAP M1 item 4). Layout per cell:
`runs/<run-id>/<toolchain>/<mode>/<package-slug>/{cell.json, diagnostics.json, build.log.gz, dia.tar.gz}`.
`run.json` records the tools commit, corpus hash, Docker version and image IDs (F7).

| Run | What it is |
|---|---|
| `2026-10-04` | First full Linux run: 5 toolchains × 33 runnable packages, 185 cells. |
| `2026-10-04-rerun` | Identical inputs, re-run for the A7 check. |
| `2026-10-10-macos` | First macOS run (ADR 0006): Lima guest, Xcode 27.0, one toolchain column, 39 cells. |
| `2026-10-10-macos-rerun` | Re-run of the above in a fresh guest clone. |

`census compare runs/2026-10-04 runs/2026-10-04-rerun` → **SET-IDENTICAL** over all 185 cells
(155 cells with diagnostics compared as multisets; 30 whose equal outcomes carry none).
`census compare runs/2026-10-10-macos runs/2026-10-10-macos-rerun` → **SET-IDENTICAL** over all 39 cells.
Linux and macOS runs are never compared or summed (F6).

## What these runs are not

- **Not the M1 exit.** `S-emit` is empty (waiting on the owner's SPI data or a decision to self-screen,
  ADR 0004 §4), so G2 (did `S-emit` emit?) cannot be evaluated. `S-byproduct` is now measured, on macOS
  (ADR 0006): LedgerKit 0 diagnostics, GRDB 8 warnings.
- **Not a result.** Roughly 40% of `S-control` cells are `build_failed`, mostly Apple-only code on
  Linux, and 6.1's wrapped identifiers are undecided (ADR 0005). Do not read frequencies off these.
- Linux runs are **aarch64**; macOS is one toolchain. The canonical column is not yet chosen (ADR 0004 §2).

## Two instrument bugs this exposed (both fixed before these runs)

- Linux SwiftPM before 6.2 emits no `.dia` unless given `-serialize-diagnostics`; without it 6.1
  cells silently reported zero diagnostics.
- At 3 GB per container, swift-syntax-heavy packages were OOM-killed mid-build, so two runs on
  identical inputs disagreed on three cells. These runs use one cell at a time with 7 GB.
