#!/usr/bin/env bash
# Note step-viewer pick text — when a user prompt carries pick blobs (the
# STEP viewer's copy format: file/solid/edge/face/click lines with
# three-decimal coordinate triples), inject a once-per-session pointer at
# the format's home and at the fact the channel is two-way: the viewer's
# Find box accepts the same format pasted back. Discovery, not
# enforcement — the format itself an agent can grep its way to, but
# nothing in a pasted blob reveals that emitting blobs is useful, so
# that's the part that needs telling. UserPromptSubmit; fires only
# inside a repo carrying the viewer (web/public/js/viewer/pick-format.js
# found by walking up from cwd); bails silently anywhere else.
#
# No Haiku stage and no logging — the coordinate-triple signature is
# unambiguous, nothing to adjudicate.

set -uo pipefail

WARNED_DIR="$HOME/.claude/hooks/state"
mkdir -p "$WARNED_DIR" 2>/dev/null || true

# Garbage-collect stale per-session noted markers (older than 7 days).
find "$WARNED_DIR" -type f -name 'pick-noted-*' -mtime +7 -delete 2>/dev/null || true

input=$(cat)
prompt=$(printf '%s' "$input" | jq -r '.prompt // empty')
[[ -z "$prompt" ]] && exit 0

# Pre-filter: the picker's signature — a three-decimal coordinate triple.
if ! printf '%s' "$prompt" | grep -qE 'x=-?[0-9]+\.[0-9]{3} y=-?[0-9]+\.[0-9]{3} z=-?[0-9]+\.[0-9]{3}'; then
  exit 0
fi

# Scope: only inside a repo that carries the step viewer.
cwd=$(printf '%s' "$input" | jq -r '.cwd // empty')
repo=""
dir="$cwd"
while [[ -n "$dir" && "$dir" != "/" ]]; do
  if [[ -f "$dir/web/public/js/viewer/pick-format.js" ]]; then
    repo="$dir"
    break
  fi
  dir=$(dirname "$dir")
done
[[ -z "$repo" ]] && exit 0

# Per-session loop guard. Note once per session; after the marker is in
# place, subsequent pick pastes in the same session pass through silently.
transcript_path=$(printf '%s' "$input" | jq -r '.transcript_path // empty')
session_id_field=$(printf '%s' "$input" | jq -r '.session_id // empty')
if [[ -n "$transcript_path" ]]; then
  session_marker=$(basename "$transcript_path" .jsonl)
elif [[ -n "$session_id_field" ]]; then
  session_marker="$session_id_field"
else
  session_marker=""
fi

if [[ -n "$session_marker" && -f "$WARNED_DIR/pick-noted-$session_marker" ]]; then
  exit 0
fi
[[ -n "$session_marker" ]] && touch "$WARNED_DIR/pick-noted-$session_marker" 2>/dev/null || true

read -r -d '' note <<'EOF' || true
The coordinate lines in this prompt are step-viewer pick text: the user clicked geometry in the repo's STEP viewer and pasted the copy blob (file/solid/edge/faceA/faceB/click lines). The format, parser, and matcher live in web/public/js/viewer/pick-format.js; web/tests/pick-format.test.js carries verbatim samples. Decode each pick against the generating CAD script and echo your identification of the feature ("that's the pill-bore ceiling flat") before changing geometry — misfires are intent gaps, not decode errors, and the echo catches them in conversation instead of in a commit.

The channel is two-way: the viewer's Find box (a toggle on any open STEP) accepts this same format pasted back — it opens the file named by a file: line, highlights every recognizable pick, and frames the camera on them. When pointing the user at geometry you built or changed, compose lines from CadQuery geometry with hardware/scripts/pick_text.py (from_edge / from_face / click / file_line — the module explains itself and is round-trip tested against the viewer's parser) and emit them in a fenced code block for the user to paste.
EOF

jq -n --arg ctx "$note" '{
  "hookSpecificOutput": {
    "hookEventName": "UserPromptSubmit",
    "additionalContext": $ctx
  }
}'
exit 0
