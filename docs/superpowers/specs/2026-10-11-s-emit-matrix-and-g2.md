# Spec — the full-corpus matrix runs, the M1 exit, and G2

**Status:** design approved by the owner (2026-10-11); spec awaiting owner review.
**Branch:** `m1/s-emit-matrix`, cut from `m1/screen-results` @ `702ea61`.
**Implements:** ROADMAP M1 exit (per A7) and G2 as redefined in ADR 0007 D8.
**Does not implement:** M2 (normalisation, coverage, ranking), the SPI validation join, or any change to the corpus.

---

## 0. Read this first

Read `CLAUDE.md`, `docs/decisions/0006`–`0007` (ADR 0007 including **Results**), `runs/README.md`, and
§0 "Facts about this machine" in `docs/superpowers/specs/2026-10-10-macos-screen.md`. That section still
applies. The facts that matter most here:

- **Docker Desktop and the macOS guest cannot run together** (16 GiB host). The Linux and macOS phases
  run one after the other. Quit Docker Desktop before any macOS run.
- `census-macos` is the golden guest. Never start it directly. `census run --platform macos` clones it.
- Wrap long runs in `caffeinate -i`.

Rules from `CLAUDE.md` that apply most directly to this work: corpus SHAs and `corpus/resolved/` are not
touched. A7 or G2 failing is investigated, never relaxed. Linux and macOS numbers are never summed (F6).

## 1. What this is

1. **A full-corpus run pair per platform.** All 66 entries (65 runnable) in `corpus/packages.yaml`, at one tools commit.
   Each pair is a run plus a re-run on identical inputs. Together these are the M1 exit: "one full run over
   all strata, results committed, and a re-run producing a set-identical normalised diagnostic multiset".
   Earlier runs (`2026-10-04*`, `2026-10-10-macos*`) predate `S-emit`, so they do not satisfy it.
2. **G2.** Among the 30 `S-emit` entries, the fraction that emit on the Linux 6.4 column, and on nightly.
   Below 50% on Linux 6.4 fails G2, and the selector is investigated before M2 (ADR 0007 D8).
3. **Screen reproduction (an extra assertion that costs no new builds).** The macOS run's `strict-complete-v5`
   cells for the 30 `S-emit` entries use the same SHA, resolved file, guest image and Xcode as their screen
   cells. They must be A7 set-identical to them. If they are not, the screen's selection input does not
   reproduce, and that is investigated before G2 is read.

## 2. Pre-registration: ADR 0008, committed before the first build

ADR 0007 is frozen above its Results, so the G2 operational rules go in a new
`docs/decisions/0008-m1-exit-runs-and-g2.md`. It is committed, and its commit SHA recorded, **before**
any cell of these runs is built. Everything in this table is fixed in that ADR:

| Item | Fixed value |
|---|---|
| G2 population | The 30 entries with `stratum: S-emit` in `corpus/packages.yaml` at the ADR's commit |
| G2 denominator | Always 30. No entry is dropped for any outcome |
| "Emits" on a column | That entry's `strict-complete-v5` cell has outcome `built` **and** ≥1 diagnostic record with `attribution: primary` and `severity ≠ note` |
| Not emitting | `built` with no such record; and every other outcome (`build_failed`, `timeout`, `unsupported_tools_version`, `resolve_failed`) |
| Why `built` only | A `build_failed` cell on Linux typically carries "no such module" errors for Apple frameworks. Those are primary, non-note diagnostics that strict concurrency checking did not cause, so counting them would inflate G2 with noise. The any-outcome fraction is still reported, labelled non-gating |
| `infra_error` | Not an outcome G2 can score. Each `infra_error` cell gets one retry (`--force` on that cell). If any `S-emit` 6.4 cell is still `infra_error` after that, G2 is **not evaluated**, and the report says why |
| Gating column | Linux `6.4` = `swift:6.4` at `sha256:4601bf61dab9485a3e93087770b72d268737e945a5b000e2286b6cc48bb048b6`, aarch64, run `2026-10-11` (the first pass, not the re-run) |
| Threshold | `emits / 30 < 0.5` → **G2 fails** (i.e. ≤14 of 30). 15 of 30 passes |
| Reported, not gating | Nightly (`swiftlang/swift:nightly-main-jammy` at `sha256:191f78f3b9570ccdd382437b07ea0e8f98750206b96c71bad4f9515ec3aed4d2`), 6.1, 6.2, 6.3, and the macOS column; per tertile (head / middle / tail) as well as overall |
| M1 exit | `census compare` SET-IDENTICAL for `2026-10-11` vs `2026-10-11-rerun` and for `2026-10-11-macos` vs `2026-10-11-macos-rerun` |
| A7 mismatch | Investigated (as with the 3 GB OOM finding in `runs/README.md`). The pair is not re-run until it comes out green. If an instrument bug is found and fixed, **both** passes of that pair are re-run at the fixed commit under new run ids |
| Images | No `docker pull` and no guest rebuild from the ADR commit until the last run finishes. Preflight asserts the IDs above and the guest restore digest `sha256:2f016638293c3e641b8b25391a76fbc16563b3711915a5551cf8aa0f5598a5c1` |

The ADR also states the obvious limit: G2 tests whether `S-emit` membership carries over to a different
platform and toolchain. It does **not** test whether `S-emit` is representative. It is selected on the
outcome (ADR 0007 Known bias 1).

## 3. Code (Swift, `tools/`, swift-testing, follows the surrounding style)

### 3.1 `census gate g2 <linux-run-dir>`

- Loads the manifest and the run's cells through `RunStore`. Computes the ADR 0008 rule per toolchain
  column for the `S-emit` entries.
- Prints, for every column: `emits/30`, the percentage, the any-outcome fraction (labelled non-gating), the
  per-tertile split (from `selection`), and per package `outcome` and primary non-note count.
- Exit codes: **0** G2 passes; **1** G2 fails; **2** not evaluable (an `S-emit` 6.4 v5 cell missing or
  `infra_error`, the run is not `linux-spm`, or the manifest's `S-emit` count is not 30).
- `--json <path>` writes the same result machine-readably, so it can be committed alongside the run.
- The scoring function is pure (`[CellKey: LoadedCell]` + manifest → result) and lives in `CensusRunner`.
  Tests use in-memory fixtures and cover: the 14/30 → fail and 15/30 → pass boundary; `build_failed` with
  primary errors scores as not emitting; notes-only and transitive-only score as not emitting; a missing or
  `infra_error` cell → not evaluable; non-`S-emit` entries are ignored.

### 3.2 Screen reproduction: `census screen reproduce <screen-id> <macos-run-dir>`

- Left side: the screen's pass-1 `strict-complete-v5` cells (`runs/<screen-id>-macos-b*/`) for the
  `S-emit` entries. Right side: the same keys from the macOS run. Compared with the existing
  `RunComparison.compare`. Cells outside those 30 keys are ignored on both sides, and that is stated in
  the output.
- Before comparing, it checks that each entry's SHA and `resolved_file_sha256` match on both sides. If
  they do not, it refuses rather than comparing different inputs.
- Exit 0 if SET-IDENTICAL, 1 otherwise. Tests: the filtering, the input-mismatch refusal, and a
  differing cell is reported.

### 3.3 Preflight: `scripts/matrix-preflight.sh`

A short script, not Swift. It asserts the five Docker image IDs, the guest digest in
`tools/vm/census-macos.yaml`, a clean `git status` in `tools/` (so `tools_git_dirty` is false, unlike earlier runs),
free disk ≥ 40 GB, and that no `census-run-*` Lima clone is left over. Exits non-zero naming the first
failure.

No other code changes. `census run` and `census compare` are used as they are.

## 4. Runs

All four runs happen at one tools commit (the commit that adds §3, after ADR 0008). The manifest hash is
identical across all four runs.

| Run id | Platform | Cells (approx.) | Command |
|---|---|---|---|
| `2026-10-11` | linux | 63 runnable (the `S-byproduct` pair is macOS-only; one `S-control` entry is skipped) × 5 toolchains v5, + 4 `S-anchor` × 5 declared = 335 | `census run --run-id 2026-10-11 --platform linux --jobs 1 --memory-gb 7` |
| `2026-10-11-rerun` | linux | same | same, `--run-id 2026-10-11-rerun` |
| `2026-10-11-macos` | macos | 65 v5 + 4 `S-anchor` declared = 69 | `census run --run-id 2026-10-11-macos --platform macos` |
| `2026-10-11-macos-rerun` | macos | same | same, fresh guest clone |

`--jobs 1 --memory-gb 7` is the setting under which the Linux pair last came out set-identical. At 3 GB,
packages heavy on swift-syntax were OOM-killed. Entries whose `platforms` exclude a platform are skipped
there by the runner, as before. Run ids use the date the plan starts. If runs start on a later date, the
ids use that date, and the ADR records the actual ids.

Each run is committed on its own (`runs/<id>/` raw bytes + parsed JSON) as soon as it finishes, before the
next one starts.

## 5. Evaluation order

1. `census compare runs/2026-10-11 runs/2026-10-11-rerun` → must be SET-IDENTICAL.
2. `census compare runs/2026-10-11-macos runs/2026-10-11-macos-rerun` → must be SET-IDENTICAL.
3. `census screen reproduce screen-2026-10-10 runs/2026-10-11-macos` → must be SET-IDENTICAL.
4. `census gate g2 runs/2026-10-11 --json runs/2026-10-11/g2.json` → the G2 verdict.

Steps 1–3 failing does not stop step 4 from running, but the write-up reports G2 as **conditional on**
the failed check, and M1 is not exited.

## 6. Write-up

- ADR 0008 **Results** (below the frozen part): actual run ids, image IDs, tools commit, the four checks'
  outputs, the G2 table (every column, overall and per tertile), and the list of `S-emit` entries that do
  not emit on Linux 6.4 with their outcome. Write a "Not verified" section, as in ADR 0007.
- `runs/README.md`: the four new runs, and an update to "What these runs are not".
- ROADMAP M1: mark the exit met or not met, with a pointer to ADR 0008. Do not mark M2 started.
- Memory note: replace the "next is S-emit matrix + G2" pointer with the outcome.

## 7. If G2 fails

Per D8: investigate the selector before M2. The plan stops at the write-up. It does **not** re-select,
re-screen or move the threshold. The investigation and any remedy get their own ADR, decided by the owner.

## 8. Out of scope

M2 work of any kind; the SPI join; the 6.1 identifier-wrapping decision (ADR 0005, still open); resolving
the three `minimal_failed` packages or the SE-0411 hypothesis; classifying the 97 `build_failed` screen
candidates; a canonical-column choice (ADR 0004 §2); and Linux x86_64.
