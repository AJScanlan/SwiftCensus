#!/bin/bash
# .claude/hooks/test-hooks.sh: exercises guard-pinned.sh and guard-bash.sh with synthetic PreToolUse inputs.
# Run after any change to either hook: `.claude/hooks/test-hooks.sh`. Exits 1 if any case fails. Reads only.
# Cases tagged [1]-[4] are regressions for gaps found by automated review of the first versions.
R="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"; H="$R/.claude/hooks"; fails=0
MAIN="$(git -C "$R" worktree list --porcelain | awk '/^worktree /{print $2; exit}')" # the main checkout

t() {
  local want=$1 hook=$2 json=$3 label=$4 out code dec got r
  out=$(printf '%s' "$json" | "$H/$hook" 2>&1); code=$?
  dec=$(jq -r '.hookSpecificOutput.permissionDecision // empty' <<<"$out" 2>/dev/null)
  if [[ $code == 2 ]]; then got=block; elif [[ -n "$dec" ]]; then got=$dec; elif [[ $code == 0 ]]; then got=pass; else got="err$code"; fi
  [[ $got == "$want" ]] && r=OK || { r=FAIL; fails=$((fails+1)); }
  printf '%-4s %-6s %s\n' "$r" "$got" "$label"
}
E() { jq -nc --arg f "$1" --arg o "${2:-x}" '{tool_name:"Edit",tool_input:{file_path:$f,old_string:$o,new_string:"y"}}'; }
W() { jq -nc --arg f "$1" '{tool_name:"Write",tool_input:{file_path:$f,content:"y"}}'; }
B() { jq -nc --arg c "$1" '{tool_name:"Bash",tool_input:{command:$c}}'; }
A10=$R/docs/decisions/0010-failed-builds-are-not-a-frequency-source.md
RES=$(awk '/^## Results/{f=1;next} f&&NF{print;exit}' "$A10")
SPAN="$(awk '/^## Results/{print prev; print; exit} NF{prev=$0}' "$A10")"

t block guard-pinned.sh "$(E "$R/runs/2026-10-11/run.json")" "edit runs/<id>/run.json"
t pass  guard-pinned.sh "$(E "$R/runs/README.md")" "edit runs/README.md"
t block guard-pinned.sh "$(W "$R/corpus/resolved/foo.resolved")" "write corpus/resolved/*"
t block guard-pinned.sh "$(E "$R/corpus/packages.yaml")" "edit corpus/packages.yaml"
t pass  guard-pinned.sh "$(E "$R/corpus/README.md")" "edit corpus/README.md"
t block guard-pinned.sh "$(E "$R/screens/screen-2026-10-10/results.json")" "edit screen results.json"
t block guard-pinned.sh "$(E "$R/tools/Package.resolved")" "edit tools/Package.resolved"
t pass  guard-pinned.sh "$(E "$R/tools/Sources/CensusRunner/Compare.swift")" "edit Compare.swift"
t pass  guard-pinned.sh "$(W "$R/runsXYZ/deep/new.txt")" "write under nonexistent dir"
t ask   guard-pinned.sh "$(E "$A10" '**A7 as written failed on 2026-10-11.**')" "ADR 0010: pre-registered text"
t pass  guard-pinned.sh "$(E "$A10" "$RES")" "ADR 0010: Results text ($RES)"
t ask   guard-pinned.sh "$(W "$A10")" "ADR 0010: full rewrite"
t ask   guard-pinned.sh "$(E "$R/docs/decisions/0009-g2-failed-investigation-and-linux-scope.md" '**G2 failed.**')" "ADR 0009 (no Results section)"
t pass  guard-pinned.sh "$(W "$R/docs/decisions/0011-new.md")" "new ADR"
[[ "$MAIN" != "$R" ]] && t block guard-pinned.sh "$(E "$MAIN/runs/2026-10-04/run.json")" "main checkout runs/ (from a worktree)"
t block guard-pinned.sh "$(E "$R/tools/../runs/2026-10-11/run.json")" "[1] tools/../runs (existing part)"
t ask   guard-pinned.sh "$(W "$R/runs-new/../runs/x.json")" "[1] .. in nonexistent part"
[[ -L "$R/work" ]] && t block guard-pinned.sh "$(E "$R/work/../runs/2026-10-04/run.json")" "[1] through the work symlink + .."
t ask   guard-pinned.sh "$(E "$A10" "$SPAN")" "[2] old_string spanning the Results heading"
t ask   guard-pinned.sh "$(E "$A10" '')" "[2] empty old_string"

t block guard-bash.sh "$(B 'tools/.build/release/census run --run-id x --force')" "census run --force"
t pass  guard-bash.sh "$(B 'caffeinate -i tools/.build/release/census run --run-id 2026-10-25 --platform linux --jobs 1 > work/a.log 2>&1')" "census run (normal)"
t block guard-bash.sh "$(B 'census resolve --package a --force')" "census resolve --force"
t pass  guard-bash.sh "$(B 'census resolve --package a')" "census resolve (normal)"
t block guard-bash.sh "$(B 'docker pull swift:6.4')" "docker pull"
t block guard-bash.sh "$(B 'docker image pull swift:6.4')" "docker image pull"
t pass  guard-bash.sh "$(B 'docker image inspect --format {{.Id}} swift:6.4')" "docker image inspect"
t block guard-bash.sh "$(B 'swift package --package-path tools update')" "swift package update"
t pass  guard-bash.sh "$(B 'swift test --package-path tools; git push --force-with-lease')" "--force on another command"
t pass  guard-bash.sh "$(B 'census run --run-id x; rm -rf --force /tmp/x')" "--force after ;"
t block guard-bash.sh "$(B $'tools/.build/release/census run --run-id x \\\n  --force')" "[3] --force on a continuation line"
t block guard-bash.sh "$(B 'census run --run-id x "--force"')" "[3] quoted --force"
t block guard-bash.sh "$(B $'docker \\\n  pull swift:6.4')" "[3] docker, continuation, pull"
t pass  guard-bash.sh "$(B $'census run --run-id x\nrm -rf --force /tmp/x')" "[3] --force on a separate line (separate command)"
t block guard-bash.sh "$(B 'census run --run-id x --force \')" "[4] trailing backslash at EOF"
t block guard-bash.sh "$(B $'census run --run-id x \\\n --force \\')" "[4] continuation then trailing backslash"
t pass  guard-bash.sh "$(B 'echo hi \')" "[4] trailing backslash, harmless"

echo "failures: $fails"
((fails == 0))
