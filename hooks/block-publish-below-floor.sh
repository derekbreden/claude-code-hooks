#!/usr/bin/env bash
# Block publishing a video that hasn't cleared the floor. The publish chain
# (marketing/video/workflow.md) opens with the thumbnail builder
# marketing/thumbnail/make.sh — the first ship action after the cut is locked.
# A cut ships with motion graphics, not captions-only: "the pipeline is the
# floor" (marketing/video/principles.md). What this catches is marching to
# publish on a feature-stripped cut — no overlays sidecar, so no title card,
# freeze, or SFX.
#
# PreToolUse on Bash: derive the working dir from the make.sh source-frame arg
# and look for an overlays sidecar next to the cut. Sidecar present → floor
# cleared → pass through silently. Sidecar absent → redirect. Working dir not
# locatable → pass through (fail-open). Detection is anchored to command
# position, so cat/ls/grep of the script don't trip it.
#
# Nudge once per session, then pass through: a deliberate music-bed Tier-2 clip
# legitimately ships without overlays, so a re-run goes through. Per-session
# marker + 7-day GC, mirroring block-flash-before-commit.sh / block-web.sh. The
# deny message carries the convention, in the register it was given.

set -uo pipefail

input=$(cat)
tool_name=$(printf '%s' "$input" | jq -r '.tool_name // empty')
[[ "$tool_name" == "Bash" ]] || exit 0
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty')
[[ -n "$cmd" ]] || exit 0

# thumbnail/make.sh <source> <output> "HEADLINE" — the publish-chain entry.
# Anchored to a command-segment start (optionally via env-assignments, sudo, or
# a shell interpreter and a leading path), so `cat .../make.sh` doesn't match.
printf '%s' "$cmd" | grep -Eq '(^|[;&|]|&&|\|\|)[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]+[[:space:]]+)*(sudo[[:space:]]+)?(bash[[:space:]]+|sh[[:space:]]+|zsh[[:space:]]+)?(\./|[^[:space:];&|]*/)?thumbnail/make\.sh([[:space:]]|$)' || exit 0

# Source frame is the first positional arg after the script token. Derive the
# working dir by walking up to the cut (the dir holding cutlist.json).
tail=$(printf '%s' "$cmd" | sed -E 's@.*thumbnail/make\.sh[[:space:]]+@@')
src=$(printf '%s' "$tail" | awk '{print $1}')
src="${src%\"}"; src="${src#\"}"; src="${src%\'}"; src="${src#\'}"
case "$src" in
  "~/"*) src="$HOME/${src#"~/"}" ;;
esac
[[ -n "$src" ]] || exit 0

dir=$(dirname "$src" 2>/dev/null) || exit 0
workdir=""
for _ in 1 2 3 4 5; do
  [[ -z "$dir" || "$dir" == "/" || "$dir" == "." ]] && break
  if [[ -f "$dir/cutlist.json" ]]; then workdir="$dir"; break; fi
  dir=$(dirname "$dir")
done
[[ -n "$workdir" ]] || exit 0   # can't locate the cut → pass through

# Floor cleared = an overlays sidecar sits next to the cut. Absent → captions-only.
shopt -s nullglob nocaseglob
sidecars=("$workdir"/*overlay*.json)
shopt -u nullglob nocaseglob
[[ ${#sidecars[@]} -gt 0 ]] && exit 0   # sidecar present → floor cleared → silent pass

# Nudge once per session, then pass through. Per-session marker + 7-day GC,
# mirroring block-flash-before-commit.sh / block-web.sh.
WARNED_DIR="$HOME/.claude/hooks/state"
mkdir -p "$WARNED_DIR" 2>/dev/null || true
find "$WARNED_DIR" -type f -name 'floor-warned-*' -mtime +7 -delete 2>/dev/null || true
transcript_path=$(printf '%s' "$input" | jq -r '.transcript_path // empty')
session_id_field=$(printf '%s' "$input" | jq -r '.session_id // empty')
if [[ -n "$transcript_path" ]]; then
  session_marker=$(basename "$transcript_path" .jsonl)
elif [[ -n "$session_id_field" ]]; then
  session_marker="$session_id_field"
else
  session_marker=""
fi
if [[ -n "$session_marker" && -f "$WARNED_DIR/floor-warned-$session_marker" ]]; then
  exit 0
fi
[[ -n "$session_marker" ]] && touch "$WARNED_DIR/floor-warned-$session_marker" 2>/dev/null || true

reason="Hold on — you're starting the publish chain, and this cut hasn't cleared the floor.

No overlays sidecar in ${workdir}. That's captions-only: no title card, no freeze, no SFX — none of the motion graphics. 'The pipeline is the floor' (marketing/video/principles.md): a captions-only cut ships BELOW the last video, not a step past it. Author the overlays.json — at minimum this video's one format advance over the last — re-render with --overlays, then come back to the thumbnail.

If this really is a deliberate music-bed clip that needs no overlays, re-run as-is and it'll go through — fires once per session."

jq -n --arg reason "$reason" '{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": $reason
  }
}'
exit 0
