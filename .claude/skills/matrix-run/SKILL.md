---
name: matrix-run
description: Freeze tools/ and run one pass of a census matrix campaign (Linux or macOS), check it, and commit it, following the procedure of plan 2026-10-11 Tasks 8–11 and spec 2026-10-18 §2. Owner-invoked only, because it starts multi-hour builds of third-party code.
disable-model-invocation: true
argument-hint: <campaign> <freeze|linux-a|linux-b|macos-a|macos-b|status>
---

# /matrix-run

Arguments: `$ARGUMENTS`. The first is the campaign directory under `work/` (e.g. `m1-exit-2`). The second is the step.
If either is missing, run `status` for the newest `work/m1-exit*` directory and ask which step to run.

A campaign is four runs at one frozen tools commit: `<D>` and `<D>-rerun` (Linux), `<D>-macos` and `<D>-macos-rerun`
(macOS), where `<D>` is the freeze date. A pair is only comparable if nothing under `tools/` or `corpus/` changed
between its passes, so most of this procedure exists to make drift impossible rather than to detect it later. When a
step's check fails, stop and report. Do not work around it: a workaround makes the run look valid when it is not. The
owner decides what happens next.

Read `work/<campaign>/FREEZE`, `DATE` and `ADR` with `cat` once at the start of each step, then use the literal values
in later commands. Worktree-isolated sessions refuse `$(cat …)` inside commands.

## status

Show `FREEZE`, `DATE` and `ADR`; which of the four run ids exist under `runs/` and whether each is committed
(`git log --oneline -1 -- runs/<id>`); whether Docker is up (`docker info`); and any leftover `census-run-*` Lima clone
(`limactl list -q`). Then name the next step.

## freeze

1. **Review first.** Ask the owner whether the `freeze-reviewer` agent has reviewed the diff since the previous freeze
   and returned `FREEZE: go`. If not, offer to run it now and stop here. A fix after the freeze forces both passes of
   every affected pair to be re-run.
2. `git status --porcelain` must print nothing.
3. Ask which ADR governs the campaign if `work/<campaign>/ADR` is missing. Write its number (e.g. `0010`) there.
4. `mkdir -p work/<campaign>`, then `git rev-parse HEAD > work/<campaign>/FREEZE` and
   `date -u +%Y-%m-%d > work/<campaign>/DATE`.
5. `swift build -c release --package-path tools 2>&1 | tail -1`, then `git push -q`.
6. `ls -d runs/<D> runs/<D>-rerun runs/<D>-macos runs/<D>-macos-rerun`. All four must be missing. If any exists, stop
   and ask: a run id is never reused.

From here until the last run is committed, no commit may touch `tools/` or `corpus/`. The preflight enforces this.

## linux-a, linux-b

Run id: `<D>` for `linux-a`, `<D>-rerun` for `linux-b`. Log: `work/<campaign>/linux-a.log` or `linux-b.log`. For
`linux-b`, `<D>` must already be committed.

1. Docker Desktop must be running. Then `scripts/matrix-preflight.sh linux <FREEZE>` must print `preflight OK`.
2. Launch with the Bash tool and `run_in_background: true`:
   ```bash
   caffeinate -i tools/.build/release/census run --run-id <run-id> --platform linux --jobs 1 --cpus 8 --memory-gb 7 --timeout-minutes 60 > work/<campaign>/<log> 2>&1
   ```
   Keep the flags exactly as written: they are the flags of the last set-identical pair (ADR 0008). A pass takes about
   1.5 h. A background command ends with this session. If the owner wants it to survive that, give them the same command
   prefixed with `nohup` and suffixed with `&` to run from Terminal.app, with the machine plugged in and the lid open.
3. If the run dies or the session ends, re-issue the identical command. It skips cells that already have `cell.json`.
   Never pass `--force`: it re-runs finished cells and destroys the resume guarantee.
4. Check: `.claude/skills/matrix-run/scripts/check-run.sh runs/<run-id> <cells> <FREEZE>`. `<cells>` is the cell count
   of the previous Linux run on the same corpus: 335 for the 2026-10-11 corpus. Check it by counting the previous run's
   `cell.json` files, not from memory.
5. **One infra retry, only if the check reports `infra_error`:**
   ```bash
   grep -rl --include=cell.json '"outcome" : "infra_error"' runs/<run-id> | tee work/<campaign>/<log>-infra.txt
   ```
   Show the list. Delete exactly those cell directories, then repeat steps 1–4 with the log `<log>-retry`. Do this
   once. Cells that are still `infra_error` stay, and the write-up records them.
6. Any other check failure, such as missing `image_id`, wrong digests, a dirty tree or a short cell count: stop. Do not
   commit, and report the check output verbatim.
7. Commit the run as soon as the check passes, in its own commit, and push:
   ```bash
   git add runs/<run-id>
   git commit -m "Run <run-id>: Linux, full corpus, 5 toolchains (ADR <ADR> first pass)"   # linux-b: "Linux re-run on identical inputs (A7)"
   git push -q
   ```
   Add the commit attribution trailer in use in this repo.

## macos-a, macos-b

Run id: `<D>-macos` or `<D>-macos-rerun`. Log: `work/<campaign>/mac-a.log` or `mac-b.log`. Both Linux runs should be
committed first. Docker and the guest do not fit in 16 GiB together, so the order is all Linux, then all macOS.

1. Quit Docker: `osascript -e 'quit app "Docker Desktop"'`. Wait until `docker info` fails, using the Monitor tool with
   an until-loop, not a foreground `sleep`.
2. `limactl list -q`. If a `census-run-*` clone is left over, show it and ask before `limactl delete -f` on it.
3. `scripts/matrix-preflight.sh macos <FREEZE>` must print `preflight OK`.
4. Launch in the background, as in the Linux steps:
   ```bash
   caffeinate -i tools/.build/release/census run --run-id <run-id> --platform macos --timeout-minutes 60 > work/<campaign>/<log> 2>&1
   ```
   About 2.4 h per pass, including the guest boot. Each run clones the golden guest and deletes the clone afterwards.
5. Check with `check-run.sh runs/<run-id> <cells> <FREEZE>` (69 cells for the 2026-10-11 corpus). Every cell must carry
   `ipsw-sha256:2f016638…`. Use the same single infra retry, and stop on any other failure.
6. Commit as in the Linux steps (`macOS, full corpus, Xcode 27.0 (ADR <ADR> first pass)`, or
   `macOS re-run in a fresh guest clone (A7)`).
7. After `macos-b`, restart Docker: `open -a "Docker Desktop"`.

## After the last run

Do not evaluate here. Evaluation follows the governing ADR's pre-registered rules (for ADR 0010: spec 2026-10-18 §3).
Point the owner at it, and suggest the `numbers-auditor` agent on the Results write-up before it is committed.
