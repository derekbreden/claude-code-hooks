#!/usr/bin/env bash
# Block effort estimates in the assistant's last message.
# Two-stage detection: cheap regex pre-filter, then Haiku disambiguation on a
# window of context around the candidate phrase(s). Fail-open on any error.
#
# Diagnostic log: every invocation appends one JSONL line to
# $HOME/.claude/hooks/logs/effort-estimate.jsonl with a "status" field
# identifying which code path was taken, so slips can be diagnosed after the
# fact (grep for status="regex_no_match" to see what got past the pre-filter).

set -euo pipefail

LOG_FILE="$HOME/.claude/hooks/logs/effort-estimate.jsonl"
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true

# Append one JSONL line to the log. Fail-open on any error so the hook never
# breaks because of logging.
log_status() {
  local status="$1"
  local extra_json="${2:-null}"
  local ts
  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  {
    if [[ "$extra_json" == "null" ]]; then
      jq -nc --arg ts "$ts" --arg status "$status" '{ts: $ts, status: $status}'
    else
      jq -nc --arg ts "$ts" --arg status "$status" --argjson extra "$extra_json" '{ts: $ts, status: $status} + $extra'
    fi
  } >> "$LOG_FILE" 2>/dev/null || true
}

input=$(cat)

# Loop guard — don't re-block a revision attempt.
stop_hook_active=$(printf '%s' "$input" | jq -r '.stop_hook_active // false')
if [[ "$stop_hook_active" == "true" ]]; then
  log_status "loop_guard"
  exit 0
fi

transcript_path=$(printf '%s' "$input" | jq -r '.transcript_path // empty')
if [[ -z "$transcript_path" || ! -f "$transcript_path" ]]; then
  log_status "no_transcript"
  exit 0
fi

# Extract the last assistant message line from the JSONL transcript.
last_line=$( (tail -r "$transcript_path" 2>/dev/null || tac "$transcript_path" 2>/dev/null) | grep -m 1 '"type":"assistant"' || true)
if [[ -z "$last_line" ]]; then
  log_status "no_assistant_message"
  exit 0
fi

last_text=$(printf '%s' "$last_line" | jq -r '(.message.content // []) | map(select(.type == "text") | .text) | join("\n")' 2>/dev/null || true)
if [[ -z "$last_text" || ${#last_text} -lt 40 ]]; then
  log_status "empty_or_short_text" "$(jq -nc --argjson len "${#last_text}" '{text_len: $len}')"
  exit 0
fi

# Strip backtick-delimited spans (fenced blocks and inline code) before pattern
# matching. Documentation that quotes the hook's own trigger patterns should
# not be classified as live agent speech.
last_text=$(printf '%s' "$last_text" | perl -0pe 's/```.*?```//gs; s/`[^`\n]+`//g' 2>/dev/null || printf '%s' "$last_text")
if [[ -z "$last_text" || ${#last_text} -lt 40 ]]; then
  log_status "empty_after_strip"
  exit 0
fi

# Pre-filter: cheap regex for candidate effort-estimate shapes.
# If nothing matches, skip the Haiku call entirely.
# The pattern is intentionally lenient — false positives are cheap (one Haiku
# call) but false negatives are silent slips. Extend it when the log shows
# something getting past.
pattern='([Hh]alf[ \-]+(an?[ ]+)?(hour|day|week|month)|[Aa]n?[ ]+(afternoon|evening|morning|hour|day|week|month|year)s?|[Aa][ ]+few[ ]+(minutes?|hours?|days?|weeks?|months?)|[Aa][ ]+couple[ ]+(of[ ]+)?(minutes?|hours?|days?|weeks?|months?|years?)|(one|two|three|four|five|six|seven|eight|nine|ten)[ ]+(minutes?|hours?|days?|weeks?|months?|years?)|~?[0-9]+[ ]*-?[ ]*(min(ute)?s?|hours?|hrs?|days?|weeks?|wks?|months?|years?|yrs?)|(minutes?|hours?|days?|weeks?|months?|years?)[ \-]*ish|weeks?[ ]+(,[ ]+)?not[ ]+months?|months?[ ]+(,[ ]+)?not[ ]+weeks?|time-to-[a-z]+|(should|would|will|might)[ ]+take|takes?[ ]+(about|roughly|a)|multi-year|several[ ]+(years?|months?|weeks?))'

if ! printf '%s\n' "$last_text" | grep -qE "$pattern"; then
  # Log the last 400 chars of the response so a future "why didn't this fire?"
  # investigation has the actual text to look at without needing the transcript.
  excerpt=$(printf '%s' "$last_text" | tail -c 400)
  log_status "regex_no_match" "$(jq -nc --argjson len "${#last_text}" --arg excerpt "$excerpt" '{text_len: $len, last_400_chars: $excerpt}')"
  exit 0
fi

# Window: ±800 chars around the first match position. Position-based rather
# than line-based, so very long unbroken paragraphs still get the match in view.
window=$(printf '%s' "$last_text" | awk -v pat="$pattern" '
  { full = full $0 "\n" }
  END {
    if (match(full, pat)) {
      start = RSTART - 800
      if (start < 1) start = 1
      end = RSTART + RLENGTH + 800
      if (end > length(full)) end = length(full)
      print substr(full, start, end - start + 1)
    }
  }
')

api_key_file="$HOME/.claude/anthropic_api_key"
if [[ ! -f "$api_key_file" ]]; then
  log_status "no_api_key"
  exit 0
fi
api_key=$(cat "$api_key_file")

classification_prompt='You will see a snippet from an AI assistant'\''s response that contains time language. Classify whether the time language is an EFFORT estimate or a PROJECTION/property description.

- effort = estimates how long someone (especially the assistant itself) will spend doing work. Examples: "this will take a few hours", "half a day of work", "weeks not months", "~4 hours", "maybe a half-day of careful work", "multi-year project".
- projection = describes outcomes, properties, regulatory cadences, or durations of states (NOT work effort). Examples: "guaranteed multi-year loss", "bottle goes flat overnight", "tank lasts months", "for as long as the service operates", "every 5 years on 3AL aluminum", "happily for a year".

Reply with exactly one word: effort or projection.

Snippet:
'

body=$(jq -n \
  --arg model "claude-haiku-4-5" \
  --arg prompt "$classification_prompt" \
  --arg msg "$window" \
  '{
    model: $model,
    max_tokens: 5,
    messages: [{role: "user", content: ($prompt + $msg)}]
  }')

response=$(curl -sS https://api.anthropic.com/v1/messages \
  -H "x-api-key: $api_key" \
  -H "content-type: application/json" \
  -H "anthropic-version: 2023-06-01" \
  --max-time 3 \
  -d "$body" 2>/dev/null || echo '{}')

classification=$(printf '%s' "$response" | jq -r '.content[0].text // empty' | tr -d '[:space:].' | tr '[:upper:]' '[:lower:]')

if [[ -z "$classification" ]]; then
  log_status "haiku_no_response"
elif [[ "$classification" == "effort" ]]; then
  log_status "blocked" "$(jq -nc --arg classification "$classification" '{classification: $classification}')"
  jq -n '{
    "decision": "block",
    "reason": "An effort estimate from you is not tied to reality. It is pattern-matched from training data, where humans wrote estimates of work they were doing — work you will do entirely differently. Rewrite the response without putting a number on how long anything will take."
  }'
else
  log_status "allowed" "$(jq -nc --arg classification "$classification" '{classification: $classification}')"
fi
