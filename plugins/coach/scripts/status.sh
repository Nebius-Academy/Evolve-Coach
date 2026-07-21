#!/usr/bin/env bash
# /litfow:status worker: GET the status and render it. Thin (backend owns the
# data); fail-soft — jq missing or backend down prints a line and exits 0.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$here/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "LITFOW: jq is required for /status (brew install jq)."; exit 0; }

user_id="$(litfow_user_id)"
encoded="$(jq -rn --arg v "$user_id" '$v|@uri')"

body="$(litfow_get "/status?user_id=${encoded}")" || {
  echo "Couldn't reach LITFOW just now — try /status again in a bit."
  exit 0
}

if [ "$(printf '%s' "$body" | jq -r '.ready // false' 2>/dev/null)" != "true" ]; then
  echo "Your AI profile is not ready yet — we need more activity to determine it."
  exit 0
fi

# Lead with the AI profile the user has reached (design: show the profile).
echo "Your AI profile: $(printf '%s' "$body" | jq -r '.ai_profile_name')"
echo

if [ "$(printf '%s' "$body" | jq -r '.atoms | length')" -eq 0 ]; then
  # No atoms left to climb toward — the top of the progression.
  echo "You've demonstrated every atom we track — nothing pending right now."
  exit 0
fi

echo "Atoms demonstrated for the next AI profile: ■ Always ◧ Sometimes □ Never ○ N/A"
echo
# One atom per line, alphabetical. A single column (not a padded grid) keeps the
# output aligned in proportional-font terminals like VS Code, where space-padded
# columns drift. jq maps each mark to its legend glyph.
printf '%s' "$body" | jq -r '
  .atoms
  | sort_by(.label)
  | .[]
  | (if   .mark == "always"    then "■"
     elif .mark == "sometimes" then "◧"
     elif .mark == "never"     then "□"
     else                           "○" end) + " " + .label'
