#!/usr/bin/env bash
# Block WebFetch — nudge once per session toward Chrome MCP, which is far more
# reliable than WebFetch (cert failures, stale page caches, stale search results
# that Chrome doesn't hit). PreToolUse on WebFetch: deny the first WebFetch of
# the session with the redirect message, then pass through — so a session where
# Chrome MCP genuinely isn't available isn't stuck. Mirrors the once-per-session
# marker used by block-residue.sh / block-underived-measurement.sh.
#
# No Haiku stage and no logging — WebFetch is unambiguous, nothing to adjudicate.

set -uo pipefail

WARNED_DIR="$HOME/.claude/hooks/state"
mkdir -p "$WARNED_DIR" 2>/dev/null || true

# Garbage-collect stale per-session warned markers (older than 7 days).
find "$WARNED_DIR" -type f -name 'webfetch-warned-*' -mtime +7 -delete 2>/dev/null || true

input=$(cat)
tool_name=$(printf '%s' "$input" | jq -r '.tool_name // empty')
[[ "$tool_name" == "WebFetch" ]] || exit 0

# Per-session loop guard. Nudge once per session; after the marker is in place,
# subsequent WebFetch calls in the same session pass through (so a session where
# Chrome MCP isn't connected can still fall back).
transcript_path=$(printf '%s' "$input" | jq -r '.transcript_path // empty')
session_id_field=$(printf '%s' "$input" | jq -r '.session_id // empty')
if [[ -n "$transcript_path" ]]; then
  session_marker=$(basename "$transcript_path" .jsonl)
elif [[ -n "$session_id_field" ]]; then
  session_marker="$session_id_field"
else
  session_marker=""
fi

if [[ -n "$session_marker" && -f "$WARNED_DIR/webfetch-warned-$session_marker" ]]; then
  exit 0
fi
[[ -n "$session_marker" ]] && touch "$WARNED_DIR/webfetch-warned-$session_marker" 2>/dev/null || true

read -r -d '' reason <<'EOF' || true
Please use Chrome MCP instead. It is far more reliable and trustworthy. WebFetch errors are not an excuse for failing to use Chrome MCP.
EOF

jq -n --arg reason "$reason" '{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": $reason
  }
}'
exit 0
