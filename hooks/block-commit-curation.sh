#!/usr/bin/env bash
# Block the git moves an agent makes when it's trying to keep another agent's
# changes out of its commit. This is the one shared worktree: every simultaneous
# agent's in-progress work shows up in `git status`, so a diff bigger than what
# you touched is the normal state, not a problem. The fix is `git add -A && git
# commit` — committing someone else's line costs nothing here. Carving the commit
# down (unstaging, selectively staging) is wasted motion; discarding the tree to
# "clean up" deletes another agent's uncommitted work, which no commit can bring
# back.
#
# PreToolUse on Bash. Two families, both denied:
#   curate  — git add -p/-i/-e, restore --staged, reset (not --soft),
#             apply --cached/--index, rm --cached
#   discard — git reset --hard, clean (not a dry run), checkout/restore of a
#             worktree path, checkout -p, stash (push)
# The discard family also trips a data-loss line in the deny message.
#
# Hard deny, every time — like block-branch.sh, not block-flash's once-per-
# session. Curating the commit is never the move in this worktree, so there's no
# retry to allow. Pass through: git add -A / <files> / . , git commit (every
# form), reset --soft, stash pop/list/show/apply/drop, clean -n/--dry-run,
# checkout <branch>, git rm <file> (no --cached), git apply <patch> (no
# --cached). The deny message carries the calibration in the register
# block-branch gave it. No \b in the patterns — BSD grep on darwin, like the
# siblings; token edges are ([[:space:]]|$) and segments stop at [^;&|].

set -uo pipefail

input=$(cat)
tool_name=$(printf '%s' "$input" | jq -r '.tool_name // empty')
[[ "$tool_name" == "Bash" ]] || exit 0
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty')
[[ -n "$cmd" ]] || exit 0

hit=""
danger=""

# ---- discard: throws away uncommitted work in the tree (another agent's) ----
# git reset --hard
printf '%s' "$cmd" | grep -Eq 'git[[:space:]]+reset[[:space:]][^;&|]*--hard([[:space:]]|$)' && danger=1
# git clean, unless it's a dry run (-n / --dry-run)
if printf '%s' "$cmd" | grep -Eq 'git[[:space:]]+clean([[:space:]]|$)'; then
  printf '%s' "$cmd" | grep -Eq 'git[[:space:]]+clean[[:space:]][^;&|]*(--dry-run|-[A-Za-z]*n)([[:space:]]|$)' || danger=1
fi
# git checkout discarding worktree paths — checkout <branch> passes
printf '%s' "$cmd" | grep -Eq 'git[[:space:]]+checkout[[:space:]]([^;&|]*[[:space:]])?--([[:space:]]|$)' && danger=1
printf '%s' "$cmd" | grep -Eq 'git[[:space:]]+checkout[[:space:]]([^;&|]*[[:space:]])?\.([[:space:]]|$)' && danger=1
printf '%s' "$cmd" | grep -Eq 'git[[:space:]]+checkout[[:space:]]([^;&|]*[[:space:]])?(-[A-Za-z]*p|--patch)([[:space:]]|$)' && danger=1
printf '%s' "$cmd" | grep -Eq 'git[[:space:]]+checkout[[:space:]]([^;&|]*[[:space:]])?[^[:space:];&|]+\.[A-Za-z0-9]+([[:space:]]|$)' && danger=1
# git restore that touches the worktree (no --staged)
if printf '%s' "$cmd" | grep -Eq 'git[[:space:]]+restore([[:space:]]|$)'; then
  printf '%s' "$cmd" | grep -Eq 'git[[:space:]]+restore[[:space:]][^;&|]*--staged([[:space:]]|$)' || danger=1
fi
# git stash push/save/default — pop/list/show/apply/drop/branch/clear pass
if printf '%s' "$cmd" | grep -Eq 'git[[:space:]]+stash([[:space:]]|$)'; then
  printf '%s' "$cmd" | grep -Eq 'git[[:space:]]+stash[[:space:]]+(list|show|pop|apply|drop|branch|clear)([[:space:]]|$)' || danger=1
fi

# ---- curate: unstage or selectively stage, to leave changes out of the commit
# git add -p/-i/-e/--patch/--interactive/--edit — interactive hunk picking
printf '%s' "$cmd" | grep -Eq 'git[[:space:]]+add[[:space:]]([^;&|]*[[:space:]])?(-[A-Za-z]*[pie]|--patch|--interactive|--edit)([[:space:]]|$)' && hit=1
# git restore — any restore is unstage-or-discard; worktree restores tripped danger above
printf '%s' "$cmd" | grep -Eq 'git[[:space:]]+restore([[:space:]]|$)' && hit=1
# git reset to unstage — reset --soft is a recommit and passes
if printf '%s' "$cmd" | grep -Eq 'git[[:space:]]+reset([[:space:]]|$)'; then
  printf '%s' "$cmd" | grep -Eq 'git[[:space:]]+reset[[:space:]][^;&|]*--soft([[:space:]]|$)' || hit=1
fi
# git apply --cached/--index — stage a hand-built patch subset
printf '%s' "$cmd" | grep -Eq 'git[[:space:]]+apply[[:space:]][^;&|]*--(cached|index)([[:space:]]|$)' && hit=1
# git rm --cached — drop a path from the index to exclude it
printf '%s' "$cmd" | grep -Eq 'git[[:space:]]+rm[[:space:]][^;&|]*--cached([[:space:]]|$)' && hit=1

[[ -n "$danger" ]] && hit=1
[[ -n "$hit" ]] || exit 0

read -r -d '' reason <<'EOF' || true
lol just commit it — all of it.

You're looking at changes you didn't make and trying to keep them out of your commit. Don't. This is the one shared worktree, so every other agent's in-progress work shows up in your `git status` — a diff bigger than the part you touched is exactly how it's supposed to look, not a thing to fix. `git add -A && git commit` and move on. Carving your own hunks back out with reset / restore --staged / apply --cached / add -p is wasted motion: nobody cares if your commit also carries someone else's line, and it almost certainly already does.
EOF

if [[ -n "$danger" ]]; then
  read -r -d '' danger_note <<'EOF' || true

And this command bites harder than that: restore / checkout / reset --hard / clean / stash don't just unstage — they delete uncommitted changes from the working tree. That's another agent's unsaved work, with no commit to get it back from. Don't reach for them here. A clean commit comes from `git add -A && git commit`, never from throwing away what's in the tree.
EOF
  reason="${reason}${danger_note}"
fi

jq -n --arg reason "$reason" '{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": $reason
  }
}'
exit 0
