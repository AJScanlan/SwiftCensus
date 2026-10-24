#!/bin/bash
# .claude/hooks/guard-pinned.sh: PreToolUse(Edit|Write|MultiEdit|NotebookEdit). Pinned inputs and recorded results are
# never hand-edited (CLAUDE.md hard rules; F1, P1, P7; "results are never reinterpreted after they are seen").
#
# Files under runs/, corpus/ and screens/ are written by `census` (through Bash) or not at all. An edit to an ADR's
# pre-registered text (anything above `## Results`) asks the owner first; an edit inside Results goes through.
#
# Exit 2 blocks the call and shows stderr to Claude. It only sees the edit tools: `sed -i` or a redirect through Bash is
# not caught here.
set -euo pipefail

input="$(cat)"
f="$(jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' <<<"$input")"
[[ -n "$f" ]] || exit 0

ask() {
  jq -n --arg r "$1" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "ask", permissionDecisionReason: $r}}'
  exit 0
}

# Relative to the repo holding the file. Worktrees live inside the main checkout, so $CLAUDE_PROJECT_DIR is not enough.
# Resolve the deepest existing directory physically, so `tools/../runs/x` and symlinked directories match as what they
# are. A `.` or `..` left in the part that does not exist yet cannot be resolved: ask.
d="$(dirname "$f")"
while [[ ! -d "$d" ]]; do d="$(dirname "$d")"; done
rest="${f#"$d"}"
[[ "/$rest/" != *"/../"* && "/$rest/" != *"/./"* ]] || ask "Path $f has . or .. in a part that does not exist yet."
d="$(cd -P "$d" && pwd -P)"
f="$d$rest"
root="$(git -C "$d" rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "$root" ]] || exit 0
rel="${f#"$root"/}"

block() { echo "Blocked by .claude/hooks/guard-pinned.sh: $rel $1" >&2; exit 2; }

case "$rel" in
  runs/README.md | corpus/README.md | screens/*.md) ;;
  runs/*)
    block "is committed run data, written by \`census run\`. It is never edited: a wrong result stays on record and is answered by a new run or ADR." ;;
  corpus/* | screens/*)
    block "is a pinned or generated input (F1, P1, P7). Changing it is a documented operation with a fresh baseline run, and it is the owner's to make." ;;
  tools/Package.resolved)
    block "pins the instrument's dependencies exactly. Bumping it is the owner's decision." ;;
  docs/decisions/[0-9]*.md)
    [[ -f "$f" ]] || exit 0 # a new ADR
    tool="$(jq -r '.tool_name' <<<"$input")"
    [[ "$tool" == "Edit" ]] || ask "Rewrites ADR $rel. Text above '## Results' is pre-registered and is not edited after results are seen. Confirm with the owner."
    old="$(jq -r '.tool_input.old_string // empty' <<<"$input")"
    if [[ -n "$old" ]] && grep -q '^## Results' "$f"; then
      # Inside Results only if the text occurs below the heading and nowhere above it. Text spanning the heading
      # occurs in neither part, so it asks.
      pre="$(awk '/^## Results/ { exit } { print }' "$f")"
      post="$(awk 'seen { print } /^## Results/ { seen = 1 }' "$f")"
      [[ "$post" == *"$old"* && "$pre" != *"$old"* ]] && exit 0
    fi
    ask "Edits ADR $rel above '## Results' (or an ADR without Results). That text is the decision record and, where pre-registered, is not edited after results are seen. Confirm with the owner." ;;
esac
exit 0
