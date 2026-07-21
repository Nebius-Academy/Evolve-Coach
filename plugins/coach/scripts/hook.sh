#!/usr/bin/env bash
# LITFOW — per-event hook handler. Wired to every lifecycle event (see
# hooks/hooks.json). It appends the *full* payload of each hook call as one JSON
# line to this session's log, $LITFOW_STATE_DIR/hooks/<session_id>.jsonl.
#
# This log is the hook-call log (see ../../docs/adr/0004-turn-capture.md):
# capture.sh reads it on Stop/SessionEnd/PreCompact and turns it into contract
# `Turn`s. It is also a live trace you can `tail -f` per session — the prompt,
# every tool call + its result (tool_name/tool_input/tool_response), MessageDisplay
# text, subagents, stops. The raw log stays strictly local (full prompt/answer/
# tool text): only the structured Turn capture.sh derives is POSTed, and the log
# is never written into the repo (../AGENTS.md). Gate: LITFOW_HOOK_LOG=0 disables
# it (which also disables capture — capture.sh has no source without it).
#
# Never breaks a session: writes only to a local file, emits nothing on
# stdout/stderr (stdout on e.g. PreToolUse would alter Claude Code's behaviour),
# and always exits 0.
#
# Reads the hook payload as JSON on stdin. The event label is passed as $1 in
# hooks.json; it falls back to the payload's own hook_event_name.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
. "$SCRIPT_DIR/lib.sh"

EVENT="${1:-}"
INPUT="$(cat)"

# Append the FULL payload to this session's hook-call log — the input capture.sh
# reads (ADR-0004). litfow_hooklog_append validates, hoists the session id to pick the
# file, and keeps invalid JSON verbatim under `raw`; the event label falls back
# to the payload's own hook_event_name when $1 is empty. It no-ops when the log
# is disabled (LITFOW_HOOK_LOG=0) and never fails us, so no gate is needed here.
litfow_hooklog_append "$EVENT" "$INPUT"

# Register identity once per session (PII → backend, off the turn stream). Detached
# like capture so it never delays the session; inline under LITFOW_EXTRACT_SYNC for tests.
if [ "$EVENT" = "SessionStart" ]; then
  if [ "${LITFOW_EXTRACT_SYNC:-0}" = "1" ]; then
    litfow_register_identity
  else
    ( litfow_register_identity ) >/dev/null 2>&1 &
    disown 2>/dev/null || true
  fi
fi

exit 0
