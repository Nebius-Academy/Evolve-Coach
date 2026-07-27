#!/usr/bin/env bash
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
. "$SCRIPT_DIR/lib.sh"

[ "${LITFOW_DISABLED:-0}" = "1" ] && exit 0
[ "${LITFOW_PROMPT_FEEDBACK:-1}" = "1" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

INPUT="$(cat)"

user_id="$(litfow_user_id)"
[ -n "$user_id" ] || exit 0

# Mode state of the chat as last known at submit time — evidence for the judge.
# {model, thinking} come from the last transcript turn that has assistant output
# (an empty segment is the just-submitted prompt, not evidence — ADR-0004 allows
# exactly these two fields); effort comes from the last hook-log event carrying
# one (the log tail bounds the read — the file is unbounded and this path runs
# before the prompt). Every step is best-effort: on any failure the key is
# absent, which the backend reads as unknown.
modes='{}'
transcript="$(printf '%s' "$INPUT" | jq -r '.transcript_path // ""' 2>/dev/null)"
if [ -n "$transcript" ] && [ -f "$transcript" ]; then
  modes="$(jq -s "$LITFOW_TRANSCRIPT_FALLBACK"' | [.[]|select(.model != null)] | last // {}' \
    "$transcript" 2>/dev/null)" || modes='{}'
  [ -n "$modes" ] || modes='{}'
fi
session_id="$(printf '%s' "$INPUT" | jq -r '.session_id // "unknown"' 2>/dev/null)"
hooklog="$(litfow_hooklog_file "$session_id")"
if [ -f "$hooklog" ]; then
  effort="$(tail -n 300 "$hooklog" 2>/dev/null | jq -rs '
    [.[].payload.effort | if type=="object" then .level else . end | select(. != null and . != "")]
    | last // ""' 2>/dev/null)"
  if [ -n "$effort" ]; then
    modes="$(printf '%s' "$modes" | jq -c --arg effort "$effort" '. + {effort: $effort}' 2>/dev/null)" || modes='{}'
    [ -n "$modes" ] || modes='{}'
  fi
fi

payload="$(printf '%s' "$INPUT" | jq -c \
  --arg user_id "$user_id" \
  --arg submitted_at "$(litfow_now)" \
  --argjson surface "$(litfow_surface_json)" \
  --argjson modes "$modes" '
  { user_id: $user_id,
    chat_id: ((.session_id // "unknown") | tostring),
    submitted_at: $submitted_at,
    prompt: { text: (.prompt // "") },
    surface: $surface }
  + $modes' \
  2>/dev/null)" || exit 0
[ -n "$payload" ] || exit 0

body="$(printf '%s' "$payload" | litfow_request POST /prompt-feedback)" || exit 0

printf '%s' "$body" | jq -c '
  select(.show == true and ((.feedback // "") != ""))
  | { hookSpecificOutput: {
        hookEventName: "UserPromptSubmit",
        additionalContext: ("Stop. Do not act on the user request or answer it. The prompt can be sharpened before you work on it — a clearer ask will get a better result. Reply with only the coaching between the tags below, word for word and nothing else, then end your turn so the user can revise their prompt and send it again:\n\n<coaching>\n" + .feedback + "\n</coaching>") } }' \
  2>/dev/null || true

exit 0
