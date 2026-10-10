#!/usr/bin/env bash
# scripts/screen-drive.sh: the unattended driver for the S-emit screen (ADR 0007; spec §10a).
#
# Launch from Terminal.app so it outlives Claude Code:
#   cd /Users/aj/iOS/SwiftCensus
#   nohup caffeinate -i scripts/screen-drive.sh screen-2026-10-10 >/dev/null 2>&1 &
#
# `caffeinate -i` prevents idle sleep only. It does NOT keep a laptop awake with the lid closed on battery: keep the
# machine plugged in with the lid open (or in clamshell mode with a display).
#
# Phases: resolve (Docker on) -> quit Docker -> pass-1 batches -> collect -> verify batches -> collect --with-verify
# -> start Docker. It stops there: the extension (D5) and selection are separate, manual steps. After a D5 extension,
# delete work/screen-state/<id>/*.done and *.retried, then relaunch; that is safe because every phase skips finished work.
#
# Idempotent: rerun after any interruption (crash, sleep, SIGKILL, session end). The on-disk cells are the truth, and
# the *.done files are only an optimisation. It never commits, and never edits tracked files except through `census`.
# On a state it does not understand it writes STOPPED with the reason and exits non-zero. It never papers over.
#
# Environment: SCREENS_ROOT (default "screens", used by the dry run); CENSUS to use a prebuilt binary.
set -euo pipefail

ID="${1:?usage: screen-drive.sh <screen-id>}"
cd "$(dirname "$0")/.."
ROOT="${SCREENS_ROOT:-screens}"
STATE="work/screen-state/$ID"
LOG="$STATE/drive.log"
mkdir -p "$STATE"

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$LOG"; }
stop() { printf '%s\n' "$*" > "$STATE/STOPPED"; log "STOPPED: $*"; exit 1; }
is_done() { [[ -f "$STATE/$1.done" ]]; }
mark_done() { touch "$STATE/$1.done"; }

if [[ -f "$STATE/STOPPED" ]]; then
  log "refusing to start: STOPPED exists ($(cat "$STATE/STOPPED")); investigate, fix, delete it, relaunch"
  exit 1
fi

# One driver at a time. A pid file left by a SIGKILLed driver is ignored once that pid is not a driver.
if [[ -f "$STATE/driver.pid" ]]; then
  old=$(cat "$STATE/driver.pid")
  if ps -p "$old" -o command= 2>/dev/null | grep -q 'screen-drive.sh'; then
    log "another driver is running (pid $old); exiting"
    exit 1
  fi
fi
echo $$ > "$STATE/driver.pid"
trap 'rm -f "$STATE/driver.pid"' EXIT

# Run a command with a wall-clock limit (seconds); a timeout is a non-zero exit. macOS has no `timeout`.
bounded() { local s="$1"; shift; perl -e 'alarm shift; exec @ARGV or exit 127' "$s" "$@"; }

# A SIGKILLed driver leaves its child `census` running. It would race this driver for the guest and the cells.
reap() {
  if pkill -KILL -f "census (screen|resolve) .*$ID" 2>/dev/null; then log "killed an orphaned census process from a previous driver"; fi
  if pkill -KILL -f 'limactl .*census-run-' 2>/dev/null; then log "killed an orphaned limactl process from a previous driver"; fi
  sleep 2
  local inst
  for inst in $(limactl list --format '{{.Name}}' 2>/dev/null | grep '^census-run-' || true); do
    log "deleting stale guest clone $inst"
    limactl stop "$inst" >/dev/null 2>&1 || true
    limactl delete --force "$inst" >>"$LOG" 2>&1 || true
  done
}

# $1: "soft" to warn and return 1 instead of writing STOPPED when Docker will not start (the final call).
docker_up() {
  local _ soft="${1:-}"
  log "probing Docker"
  bounded 20 docker info >/dev/null 2>&1 && return 0
  log "starting Docker Desktop"
  if ! open -a Docker; then
    [[ "$soft" == soft ]] && { log "WARNING: could not launch Docker Desktop; start it by hand"; return 1; }
    stop "could not launch Docker Desktop"
  fi
  for _ in $(seq 1 100); do bounded 20 docker info >/dev/null 2>&1 && return 0; sleep 3; done
  [[ "$soft" == soft ]] && { log "WARNING: Docker Desktop did not restart; start it by hand"; return 1; }
  stop "Docker did not come up within 300 s"
}

# Docker's VM (7.75 GiB) and the macOS guest (10 GiB) cannot coexist in 16 GiB (spec §0, G2).
docker_down() {
  pgrep -f 'Docker.app/Contents' >/dev/null 2>&1 || return 0
  log "quitting Docker Desktop before the macOS phase"
  osascript -e 'quit app "Docker Desktop"' >/dev/null 2>&1 || true
  local _
  for _ in $(seq 1 60); do pgrep -f 'Docker.app/Contents' >/dev/null 2>&1 || return 0; sleep 2; done
  stop "Docker Desktop did not quit within 120 s; the guest cannot run beside it"
}

check_disk() {
  local free
  free=$(df -g . | awk 'NR==2 {print $4}')
  (( free >= 25 )) || stop "only ${free} GB free; each guest clone grows the sparse image (spec §0)"
}

log "driver start (pid $$) for $ROOT/$ID"
reap

CENSUS="${CENSUS:-}"
if [[ -z "$CENSUS" ]]; then
  log "building census"
  swift build -c release --package-path tools >>"$LOG" 2>&1 || stop "swift build failed; see $LOG"
  CENSUS="tools/.build/release/census"
fi
run_census() { "$CENSUS" "$@" >>"$LOG" 2>&1; }

# $1: "" for pass 1 or "--verify"; $2: marker prefix ("batch" or "verify").
batch_loop() {
  local flag="$1" prefix="$2" total n rc
  # shellcheck disable=SC2086
  total=$("$CENSUS" screen batches "$ID" --root "$ROOT" $flag 2>>"$LOG") || stop "cannot count $prefix batches; see $LOG"
  for (( n = 1; n <= total; n++ )); do
    is_done "$prefix-$n" && continue
    check_disk
    log "phase: $prefix $n/$total"
    set +e
    # shellcheck disable=SC2086
    run_census screen batch "$ID" "$n" --root "$ROOT" $flag
    rc=$?
    if (( rc == 3 )) && [[ ! -f "$STATE/$prefix-$n.retried" ]]; then
      touch "$STATE/$prefix-$n.retried"
      log "infra_error cells or guest boot failure in $prefix $n; retrying once"
      # shellcheck disable=SC2086
      run_census screen batch "$ID" "$n" --root "$ROOT" $flag --retry-infra
      rc=$?
    fi
    set -e
    (( rc == 0 )) || stop "$prefix $n exited $rc (3 = infra_error cells or guest boot failure, after one retry); see $LOG. If the cause is fixed, delete $STATE/$prefix-$n.retried as well as STOPPED to allow one more retry"
    mark_done "$prefix-$n"
  done
}

[[ -f "$ROOT/$ID/candidates.yaml" ]] || stop "no $ROOT/$ID/candidates.yaml; draw first (census select screen)"

if ! is_done resolve; then
  docker_up
  stale=$(bounded 30 docker ps -aq --filter name=census-resolve- 2>/dev/null || true)
  # shellcheck disable=SC2086
  [[ -z "$stale" ]] || bounded 60 docker rm -f $stale >/dev/null 2>&1 || true
  log "phase: resolve"
  run_census resolve --manifest "$ROOT/$ID/candidates.yaml" --resolved "$ROOT/$ID/resolved" --toolchain 6.4 --allow-failures \
    || stop "census resolve failed outright (an INFRA line in the log means Docker or network, not a package; fix it and relaunch, resolve resumes); see $LOG"
  mark_done resolve
fi

docker_down
batch_loop "" batch

if ! is_done collect; then
  log "phase: collect"
  run_census screen collect "$ID" --root "$ROOT" || stop "collect failed (missing cells or a denominator mismatch); see $LOG"
  mark_done collect
fi

batch_loop "--verify" verify

if ! is_done collect-verify; then
  log "phase: collect --with-verify"
  run_census screen collect "$ID" --root "$ROOT" --with-verify \
    || stop "collect --with-verify failed (missing verify cells, or stable emitters not set-identical); see $LOG"
  mark_done collect-verify
fi

docker_up soft || true
log "finished: commit the outputs, then apply D5 if needed (runbook step 8) and select (step 9)"
