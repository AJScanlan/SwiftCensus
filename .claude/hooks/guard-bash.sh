#!/bin/bash
# .claude/hooks/guard-bash.sh: PreToolUse(Bash). Blocks the commands CLAUDE.md "Running the matrix" and ADR 0008 forbid.
# Exit 2 blocks the call and shows stderr to Claude. The owner can still run any of these in their own terminal.
set -euo pipefail

c="$(jq -r '.tool_input.command // empty')"
[[ -n "$c" ]] || exit 0

# Normalise before matching: join backslash-newline continuations (the plans write `census run` that way), make every
# other newline a command separator, and drop quotes so `"--force"` matches. A heuristic, not a shell parser.
c="$(printf '%s' "$c" | sed -e ':a' -e '/\\$/N; s/\\\n/ /; ta' | tr '\n' ';' | tr -d "'\"")"

deny() { echo "Blocked by .claude/hooks/guard-bash.sh: $1" >&2; exit 2; }
has() { grep -qE "$1" <<<"$c"; }

# Within one simple command: no ; & | between the words.
if has 'census[^;&|]*[[:space:]]run[[:space:]][^;&|]*--force'; then
  deny "never \`census run --force\`. Re-issue the identical command to resume; retry one cell by deleting its directory."
fi
if has 'census[^;&|]*[[:space:]]resolve[[:space:]][^;&|]*--force'; then
  deny "\`census resolve --force\` overwrites vendored Package.resolved files (F1). Re-pinning is the owner's documented operation."
fi
if has 'docker[[:space:]]+(image[[:space:]]+)?pull'; then
  deny "Linux images are pinned by digest (ADR 0008, scripts/matrix-preflight.sh). Nothing is pulled until the owner says so."
fi
if has 'swift[[:space:]]+package[^;&|]*[[:space:]]update'; then
  deny "Package.resolved files are pinned deliberately; bumping one invalidates cross-run comparability."
fi
exit 0
