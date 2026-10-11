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
| `screen-2026-10-10-macos-b1` … `-b6` | The `S-emit` screen (ADR 0007): 300 candidates in six batches of 50, Xcode 27.0, `strict-complete-v5` plus `minimal-v5` where needed. 62 / 63 / 68 / 63 / 63 / 61 cells (380). |
| `screen-2026-10-10-macos-verify` | Stability pass: the 47 emitters re-run in both modes in a fresh guest clone, 94 cells. |
| `2026-10-11` | M1-exit Linux run (ADR 0008): full corpus, 5 toolchains, 335 cells. G2 is scored on this run (`g2.json`). |
| `2026-10-11-rerun` | Identical inputs, re-run for the A7 check. Its 268 `swift:6.1`–`6.4` cells have no `image_id` (ADR 0008 Results). |
| `2026-10-11-macos` | M1-exit macOS run (ADR 0008): full corpus, Xcode 27.0, 69 cells. |
| `2026-10-11-macos-rerun` | Re-run of the above in a fresh guest clone. |

`census compare runs/2026-10-04 runs/2026-10-04-rerun` → **SET-IDENTICAL** over all 185 cells
(155 cells with diagnostics compared as multisets; 30 whose equal outcomes carry none).
`census compare runs/2026-10-10-macos runs/2026-10-10-macos-rerun` → **SET-IDENTICAL** over all 39 cells.
`census screen collect --with-verify` → A7 over 47 stable emitters: 94 cells compared, 94 set-identical.
`census compare runs/2026-10-11 runs/2026-10-11-rerun` → **NOT SET-IDENTICAL**: 1 of 335 cells differs
(`6.4` `Quick/Nimble`, `build_failed` on both passes).
`census compare runs/2026-10-11-macos runs/2026-10-11-macos-rerun` → **NOT SET-IDENTICAL**: 1 of 69 cells differs
(`customerio/customerio-ios`, `build_failed` on both passes).
`census screen reproduce screen-2026-10-10 runs/2026-10-11-macos` → **SET-IDENTICAL** over the 30 `S-emit` cells.
Screen cells are candidates, not corpus entries; their results live in `screens/screen-2026-10-10/results.json`.
Linux and macOS runs are never compared or summed (F6).

## What these runs are not

- **Not the M1 exit.** The `2026-10-11` pairs were meant to be (ADR 0008), but neither is set-identical: one
  `build_failed` cell differs in each. **G2 fails**: 8 of 30 `S-emit` entries emit on Linux 6.4 (21 of the 22 that do not
  are `build_failed` on Linux). See ADR 0008 Results. `S-byproduct` is measured on macOS (ADR 0006): LedgerKit 0
  diagnostics, GRDB 8 warnings.
- **Not a result.** Roughly 40% of `S-control` cells are `build_failed`, mostly Apple-only code on
  Linux, and 6.1's wrapped identifiers are undecided (ADR 0005). Do not read frequencies off these.
- Linux runs are **aarch64**; macOS is one toolchain. The canonical column is not yet chosen (ADR 0004 §2).

## Two instrument bugs this exposed (both fixed before these runs)

- Linux SwiftPM before 6.2 emits no `.dia` unless given `-serialize-diagnostics`; without it 6.1
  cells silently reported zero diagnostics.
- At 3 GB per container, swift-syntax-heavy packages were OOM-killed mid-build, so two runs on
  identical inputs disagreed on three cells. These runs use one cell at a time with 7 GB.
