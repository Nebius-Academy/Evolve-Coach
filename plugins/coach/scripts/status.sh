#!/usr/bin/env bash
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$here/lib.sh"

[ "${LITFOW_DISABLED:-0}" = "1" ] && exit 0
command -v jq >/dev/null 2>&1 || exit 0

INPUT="$(cat)"
submitted="$(printf '%s' "$INPUT" | jq -r '.prompt // ""' 2>/dev/null)"
read -r command _ <<<"$submitted"
[ "$command" = "/$(litfow_plugin_name):status" ] || exit 0

reply_verbatim() {
  [ -n "$1" ] || return 0
  jq -cn --arg ctx "The user ran /$(litfow_plugin_name):status. Reply with only the following, verbatim — every line, nothing else — then end your turn:

$1" '{ hookSpecificOutput: { hookEventName: "UserPromptSubmit", additionalContext: $ctx } }'
}

render_status() {
  local body="$1"
  if [ "$(printf '%s' "$body" | jq -r '.ready // false' 2>/dev/null)" != "true" ]; then
    echo "Your AI profile is not ready yet — we need more activity to determine it."
    return 0
  fi
  echo "Your AI profile: $(printf '%s' "$body" | jq -r '.ai_profile_name')"
  echo
  if [ "$(printf '%s' "$body" | jq -r '.atoms | length')" -eq 0 ]; then
    echo "You've demonstrated every atom we track — nothing pending right now."
    return 0
  fi
  echo "Atoms demonstrated for the next AI profile: ■ Always ◧ Sometimes □ Never ○ N/A"
  echo
  printf '%s' "$body" | jq -r '
    .atoms
    | sort_by(.label)
    | .[]
    | (if   .mark == "always"    then "■"
       elif .mark == "sometimes" then "◧"
       elif .mark == "never"     then "□"
       else                           "○" end) + " " + .label'
}

user_id="$(litfow_user_id)"
encoded="$(jq -rn --arg v "$user_id" '$v|@uri')"

body="$(litfow_request GET "/status?user_id=${encoded}")"; rc=$?
if [ "$rc" -ne 0 ]; then
  # 4xx (auth/identity, rc 2) vs unreachable/5xx (rc 1) — reported apart.
  if [ "$rc" -eq 2 ]; then
    reply_verbatim "Evolve Coach couldn't authorize this request — your organization's access token looks missing or invalid. Check the plugin's managed settings."
  else
    reply_verbatim "Couldn't reach Evolve Coach just now — try /status again in a bit."
  fi
  exit 0
fi

reply_verbatim "$(render_status "$body")"
exit 0
