#!/usr/bin/env bash
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
. "$SCRIPT_DIR/lib.sh"

[ "${LITFOW_DISABLED:-0}" = "1" ] && exit 0
[ "${LITFOW_PROMPT_FEEDBACK:-1}" = "1" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

FEEDBACK_UNAVAILABLE="No feedback ready yet — we need a bit more of your work to go on."

reply_to_agent() {
  [ -n "$1" ] || return 0
  jq -cn --arg ctx "$1" '{ hookSpecificOutput: { hookEventName: "UserPromptSubmit", additionalContext: $ctx } }'
}

reply_from_command() {
  reply_to_agent "The user asked Evolve Coach for feedback on their previous prompt. Reply with only the following, word for word and nothing else, then end your turn:

Coach Feedback:
$1"
}

reply_from_prompt() {
  reply_to_agent "Stop. Do not act on the user's request or answer it — the prompt can be sharpened first. Reply with only the following, word for word and nothing else, then end your turn:

Coach Feedback:
$1

Rewrite prompt or type \"send anyway\" to use original prompt"
}

collect_modes() {
  local transcript="$1" session_id="$2" modes='{}' hooklog effort
  if [ -n "$transcript" ] && [ -f "$transcript" ]; then
    modes="$(jq -s "$LITFOW_TRANSCRIPT_FALLBACK"' | [.[]|select(.model != null)] | last // {}' "$transcript" 2>/dev/null)" || modes='{}'
    [ -n "$modes" ] || modes='{}'
  fi
  hooklog="$(litfow_hooklog_file "$session_id")"
  if [ -f "$hooklog" ]; then
    effort="$(tail -n 300 "$hooklog" 2>/dev/null | jq -rs '
      [.[].payload.effort | if type=="object" then .level else . end | select(. != null and . != "")] | last // ""' 2>/dev/null)"
    [ -n "$effort" ] && { modes="$(printf '%s' "$modes" | jq -c --arg e "$effort" '. + {effort: $e}' 2>/dev/null)" || modes='{}'; [ -n "$modes" ] || modes='{}'; }
  fi
  printf '%s' "$modes"
}

last_genuine_prompt() {
  local transcript="$1"
  [ -n "$transcript" ] && [ -f "$transcript" ] || return 0
  jq -rs "$LITFOW_CLEAN_DEF"'
    def ptext: (.message.content) as $c
      | if ($c|type)=="string" then $c else ([$c[]?|select(.type=="text")|.text]|join("\n")) end;
    [ .[] | select(.type=="user" and ((.isMeta)!=true)) | clean(ptext) | select(length>0 and (startswith("/")|not)) ] | last // ""' \
    "$transcript" 2>/dev/null
}

INPUT="$(cat)"

user_id="$(litfow_user_id)"
[ -n "$user_id" ] || exit 0

transcript="$(printf '%s' "$INPUT" | jq -r '.transcript_path // ""' 2>/dev/null)"
session_id="$(printf '%s' "$INPUT" | jq -r '.session_id // "unknown"' 2>/dev/null)"
submitted="$(printf '%s' "$INPUT" | jq -r '.prompt // ""' 2>/dev/null)"

read -r command _ <<<"$submitted"
on_demand=0
if [ "$command" = "/$(litfow_plugin_name):feedback" ]; then
  on_demand=1
fi

prompt_text="$submitted"
if [ "$on_demand" = "1" ]; then
  prompt_text="$(last_genuine_prompt "$transcript")"
  [ -n "$prompt_text" ] || { reply_from_command "$FEEDBACK_UNAVAILABLE"; exit 0; }
fi

payload="$(jq -cn \
  --arg user_id "$user_id" \
  --arg chat_id "$session_id" \
  --arg submitted_at "$(litfow_now)" \
  --arg prompt_text "$prompt_text" \
  --argjson on_demand "$on_demand" \
  --argjson surface "$(litfow_surface_json)" \
  --argjson modes "$(collect_modes "$transcript" "$session_id")" '
  { user_id: $user_id, chat_id: $chat_id, submitted_at: $submitted_at, prompt: { text: $prompt_text }, surface: $surface }
  + (if $on_demand == 1 then { on_demand: true } else {} end) + $modes' 2>/dev/null)" || exit 0
[ -n "$payload" ] || exit 0

body="$(printf '%s' "$payload" | litfow_request POST /prompt-feedback)" || {
  [ "$on_demand" = "1" ] && reply_from_command "$FEEDBACK_UNAVAILABLE"
  exit 0
}

feedback="$(printf '%s' "$body" | jq -r 'if (.show == true and ((.feedback // "") != "")) then .feedback else "" end' 2>/dev/null)"

if [ "$on_demand" = "1" ]; then
  reply_from_command "${feedback:-$FEEDBACK_UNAVAILABLE}"
  exit 0
fi

[ -n "$feedback" ] && reply_from_prompt "$feedback"
exit 0
