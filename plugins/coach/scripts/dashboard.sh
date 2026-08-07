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
[ "$command" = "/$(litfow_plugin_name):dashboard" ] || exit 0

reply_verbatim() {
  [ -n "$1" ] || return 0
  jq -cn --arg ctx "The user ran /$(litfow_plugin_name):dashboard. Reply with only the following, verbatim — every line, nothing else — then end your turn:

$1" '{ hookSpecificOutput: { hookEventName: "UserPromptSubmit", additionalContext: $ctx } }'
}

open_url() {
  command -v open >/dev/null 2>&1 && open "$1" >/dev/null 2>&1
}

user_id="$(litfow_user_id)"
body="$(jq -cn --arg u "$user_id" '{user_id:$u}')"

resp="$(printf '%s' "$body" | litfow_request POST "/dashboard/provision")"; rc=$?
if [ "$rc" -ne 0 ]; then
  if [ "$rc" -eq 2 ]; then
    reply_verbatim "Evolve Coach couldn't authorize this request — your organization's access token looks missing or invalid. Check the plugin's managed settings."
  else
    reply_verbatim "Couldn't reach Evolve Coach just now — try /dashboard again in a bit."
  fi
  exit 0
fi

token="$(printf '%s' "$resp" | jq -r '.token // empty' 2>/dev/null)"
if [ -z "$token" ]; then
  reply_verbatim "Evolve Coach returned an unexpected response — try /dashboard again in a bit."
  exit 0
fi

encoded="$(jq -rn --arg v "$token" '$v|@uri')"
url="${LITFOW_BACKEND_URL}/insights/start?p=${encoded}"
open_url "$url"

reply_verbatim "Opening your Evolve Coach dashboard in the browser — sign in with your organization account and it will load automatically.

Didn't open? Use this one-time link (valid ~2 minutes):
$url"
exit 0
