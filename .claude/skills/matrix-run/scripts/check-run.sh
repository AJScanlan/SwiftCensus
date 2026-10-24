#!/bin/bash
# check-run.sh <run-dir> <expected-cells> <freeze-commit>: the post-run checks (plan 2026-10-11 Task 9 Step 3).
# Prints the counts and exits 1 naming every check that failed. It reads only; it never deletes or retries anything.
set -uo pipefail
usage="usage: check-run.sh runs/<run-id> <expected-cells> <freeze-commit>"
RUN="${1:?$usage}"; WANT="${2:?$usage}"; FREEZE="${3:?$usage}"
cd "$(git rev-parse --show-toplevel)" || exit 1
[[ -f "$RUN/run.json" ]] || { echo "check FAILED: $RUN/run.json is missing"; exit 1; }

problems=()
cells="$(find "$RUN" -name cell.json | wc -l | tr -d ' ')"
echo "cells: $cells (expected $WANT)"
[[ "$cells" == "$WANT" ]] || problems+=("$cells cells, expected $WANT")

echo "outcomes:"
find "$RUN" -name cell.json -exec jq -r .outcome {} + | sort | uniq -c
infra="$(find "$RUN" -name cell.json -exec jq -r 'select(.outcome == "infra_error") | input_filename' {} + | wc -l | tr -d ' ')"
[[ "$infra" == 0 ]] || problems+=("$infra infra_error cells (one retry allowed: delete those cell directories, re-issue the identical command)")

echo "image_id:"
find "$RUN" -name cell.json -exec jq -r '.image_id // "nil"' {} + | sort | uniq -c
pinned="$(grep -oE '(sha256:[0-9a-f]{64})' scripts/matrix-preflight.sh | sort -u)"
while read -r id; do
  [[ -n "$id" ]] || continue
  case "$id" in
    nil) problems+=("cells without image_id: the image lookup did not refuse the run (spec 2026-10-18 §1.2)") ;;
    ipsw-sha256:*) grep -q "${id#ipsw-}" <<<"$pinned" || problems+=("guest image $id is not the pinned digest") ;;
    *) grep -qx "$id" <<<"$pinned" || problems+=("image $id is not pinned in scripts/matrix-preflight.sh") ;;
  esac
done < <(find "$RUN" -name cell.json -exec jq -r '.image_id // "nil"' {} + | sort -u)

dirty="$(jq -r .tools_git_dirty "$RUN/run.json")"
commit="$(jq -r .tools_git_commit "$RUN/run.json")"
echo "tools_git_commit: $commit   tools_git_dirty: $dirty   manifest: $(jq -r .corpus_manifest_sha256 "$RUN/run.json")"
[[ "$dirty" == false ]] || problems+=("tools_git_dirty is $dirty")
if git cat-file -e "$commit^{commit}" 2>/dev/null; then
  [[ -z "$(git diff --name-only "$FREEZE" "$commit" -- tools corpus)" ]] || problems+=("tools/ or corpus/ at $commit differs from FREEZE $FREEZE")
else
  problems+=("tools_git_commit $commit is not a commit here")
fi

if ((${#problems[@]})); then
  printf 'check FAILED: %s\n' "${problems[@]}"
  exit 1
fi
echo "check OK"
