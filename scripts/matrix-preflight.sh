#!/bin/bash
# scripts/matrix-preflight.sh: refuse to start an M1-exit run whose inputs are not ADR 0008's (spec 2026-10-11 §3.3).
#
#   scripts/matrix-preflight.sh linux <freeze-commit>   before each Linux run (Docker Desktop running)
#   scripts/matrix-preflight.sh macos <freeze-commit>   before each macOS run (Docker Desktop quit)
#
# <freeze-commit> is the tools commit all four runs use. Exits 1 naming the first failure. PREFLIGHT_ID_64 overrides the
# 6.4 pin only so the failure path can be tested; never set it for a run. bash 3.2: no associative arrays.
set -euo pipefail
cd "$(dirname "$0")/.."

usage="usage: matrix-preflight.sh linux|macos <freeze-commit>"
PLATFORM="${1:?$usage}"
FREEZE="${2:?$usage}"

# ADR 0008: the images the 2026-10-04 pair recorded. Nothing is pulled until the last M1-exit run is committed.
IMAGES=(
  "swift:6.1=sha256:6e43114610e161e38ad41636ebcafd6940dc67dfab355eace3a0ca100b2263db"
  "swift:6.2=sha256:eccc7a97f9b9881d9659e2e788081fd7675f86d39793b51200bfb178398b3784"
  "swift:6.3=sha256:cd45c27b3abc42310c33cfaf3008b18156cbdc9187834c9617e8f43a26d2675c"
  "swift:6.4=${PREFLIGHT_ID_64:-sha256:4601bf61dab9485a3e93087770b72d268737e945a5b000e2286b6cc48bb048b6}"
  "swiftlang/swift:nightly-main-jammy=sha256:191f78f3b9570ccdd382437b07ea0e8f98750206b96c71bad4f9515ec3aed4d2"
)
GUEST_DIGEST="sha256:2f016638293c3e641b8b25391a76fbc16563b3711915a5551cf8aa0f5598a5c1"
MIN_FREE_GB=40

fail() { echo "preflight FAILED: $*" >&2; exit 1; }

git rev-parse --verify --quiet "$FREEZE^{commit}" >/dev/null || fail "$FREEZE is not a commit"
[[ -z "$(git status --porcelain -- tools corpus)" ]] || fail "tools/ or corpus/ has uncommitted changes"
[[ -z "$(git diff --name-only "$FREEZE" HEAD -- tools corpus)" ]] || fail "tools/ or corpus/ changed since $FREEZE"

free_kb="$(df -k . | tail -1 | tr -s ' ' | cut -d' ' -f4)"
(( free_kb >= MIN_FREE_GB * 1024 * 1024 )) || fail "only $((free_kb / 1024 / 1024)) GB free; need $MIN_FREE_GB"

case "$PLATFORM" in
  linux)
    docker info >/dev/null 2>&1 || fail "Docker is not running"
    for pair in "${IMAGES[@]}"; do
      image="${pair%%=*}"
      want="${pair#*=}"
      # One image per call: on this Docker, `docker image inspect a b` reports bare `swift:` tags as missing.
      got="$(docker image inspect --format '{{.Id}}' "$image" 2>/dev/null)" || fail "$image is not present (do not pull: ADR 0008)"
      [[ "$got" == "$want" ]] || fail "$image is $got; ADR 0008 pins $want"
    done
    ;;
  macos)
    if docker info >/dev/null 2>&1; then fail "Docker Desktop is running; quit it first (it and the guest do not fit in 16 GiB)"; fi
    grep -q "digest: \"$GUEST_DIGEST\"" tools/vm/census-macos.yaml || fail "tools/vm/census-macos.yaml does not pin $GUEST_DIGEST"
    if limactl list -q 2>/dev/null | grep -q '^census-run-'; then fail "a census-run-* Lima clone is left over; limactl delete -f it"; fi
    ;;
  *) fail "platform must be linux or macos, not $PLATFORM" ;;
esac
echo "preflight OK ($PLATFORM, freeze $FREEZE)"
