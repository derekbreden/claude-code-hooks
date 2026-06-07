#!/usr/bin/env bash
# Block branch creation. Work happens directly on main, in the one shared
# worktree; a branch gives no isolation here and just hides work from the other
# agents on the same checkout. PreToolUse on Bash: deny the git commands that
# start or publish a branch — checkout -b/-B, switch -c/-C, branch <newname>,
# worktree add, gh pr create, and push -u/--set-upstream to a non-main branch.
# Listing/deleting/renaming branches and pushing main pass through.
#
# Hard deny, every time (not once-per-session). The deny message carries the
# calibration, in the register it was given.

set -uo pipefail

input=$(cat)
tool_name=$(printf '%s' "$input" | jq -r '.tool_name // empty')
[[ "$tool_name" == "Bash" ]] || exit 0
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty')
[[ -n "$cmd" ]] || exit 0

hit=""
# checkout -b/-B  |  switch -c/-C
printf '%s' "$cmd" | grep -Eq 'git[[:space:]]+(checkout[[:space:]]+-[bB]|switch[[:space:]]+-[cC])([[:space:]]|$)' && hit=1
# git branch <newname> — a bareword after `branch` creates; -d/-D/-m/-a/-v/--list start with '-' and pass
printf '%s' "$cmd" | grep -Eq 'git[[:space:]]+branch[[:space:]]+[A-Za-z0-9._/]' && hit=1
# git worktree add — all work stays in the one shared worktree
printf '%s' "$cmd" | grep -Eq 'git[[:space:]]+worktree[[:space:]]+add([[:space:]]|$)' && hit=1
# gh pr create — nothing to PR if we never leave main
printf '%s' "$cmd" | grep -Eq 'gh[[:space:]]+pr[[:space:]]+create([[:space:]]|$)' && hit=1
# git push -u/--set-upstream <remote> <non-main branch>
printf '%s' "$cmd" | perl -ne 'if (/git\s+push\b.*?(?:-u|--set-upstream)\s+\S+\s+(?!main(?:\b|\s|$))(?!master(?:\b|\s|$))\S+/) { $f=1 } END { exit($f ? 0 : 1) }' && hit=1

[[ -n "$hit" ]] || exit 0

read -r -d '' reason <<'EOF' || true
lol just commit to main.

We prefer to have conflicts raised early and often. All work of simultaneous agents occurs in the same worktree, and so branching wouldn't even give you any isolation in the first place — you're just confusing other agents. Leave the damn worktree on main, and commit there, and realize that this means you will encounter conflicts, but you will do so in real time, as they happen, and we can better coordinate the conflict resolution there. In practice, this usually means there aren't any conflicts at all, and the worst that happens is you commit someone else's work or they commit yours, and no one ever cares about that — just make sure it's committed (it probably is) and stop worrying about it.
EOF

jq -n --arg reason "$reason" '{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": $reason
  }
}'
exit 0
