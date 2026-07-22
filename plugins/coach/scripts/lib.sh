# shellcheck shell=bash
# Shared helpers for the LITFOW capture hooks.
#
# Sourced by hook.sh (every event) and capture.sh (Stop/SessionEnd/PreCompact).
# Pure bash + jq + curl. macOS-only PoC.
#
# The backend owns the data. The plugin POSTs turns to it and keeps only
# transient bookkeeping under LITFOW_STATE_DIR: posted-turns-<session>
# (turn ids already sent, for dedup).

# --- Configuration (override via environment) -------------------------------

LITFOW_STATE_DIR="${LITFOW_STATE_DIR:-$HOME/.claude/litfow}"

# The local Claude config the account identity is read from.
LITFOW_CLAUDE_CONFIG="${LITFOW_CLAUDE_CONFIG:-$HOME/.claude.json}"

# The backend base URL. Defaults to the deployed stand; point at a local backend
# (http://localhost:8787) for development.
LITFOW_BACKEND_URL="${LITFOW_BACKEND_URL:-https://litfow.internal-services.stands.evolve.nebius.com}"
LITFOW_HTTP_TIMEOUT="${LITFOW_HTTP_TIMEOUT:-5}"

# Identifies this surface on every turn (contract: surface.id).
LITFOW_SURFACE="${LITFOW_SURFACE:-claude-code}"
LITFOW_SURFACE_VERSION="${LITFOW_SURFACE_VERSION:-}"
if [ -z "$LITFOW_SURFACE_VERSION" ] && [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] \
  && [ -f "$CLAUDE_PLUGIN_ROOT/.claude-plugin/plugin.json" ]; then
  LITFOW_SURFACE_VERSION="$(jq -r '.version // ""' "$CLAUDE_PLUGIN_ROOT/.claude-plugin/plugin.json" 2>/dev/null || echo "")"
fi

# --- Helpers ----------------------------------------------------------------

litfow_init_dirs() {
  mkdir -p "$LITFOW_STATE_DIR"
}

# UTC timestamp, ISO-8601.
litfow_now() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

# user_id = the Claude account UUID from local config (opaque; backend maps it to
# personal data). Undocumented Claude internal — empty if absent.
litfow_user_id() {
  local id
  id="$(jq -r '.oauthAccount.accountUuid // empty' "$LITFOW_CLAUDE_CONFIG" 2>/dev/null || true)"
  printf '%s' "$id" | tr -d '\n' | cut -c1-256
}

# Register the account's PII to /identity once per session — keeps PII off the turn
# stream. Best-effort/silent; skips when there is no account.
litfow_register_identity() {
  local payload
  payload="$(jq -c '.oauthAccount
      | select(.accountUuid != null)
      | { user_id: .accountUuid, email: .emailAddress,
          organization_id: .organizationUuid, organization_name: .organizationName,
          display_name: .displayName }' "$LITFOW_CLAUDE_CONFIG" 2>/dev/null)" || return 0
  [ -n "$payload" ] || return 0
  printf '%s' "$payload" | litfow_post /identity >/dev/null 2>&1 || true
}

# Append a debug line when LITFOW_DEBUG=1. Never writes prompt/answer text.
litfow_debug() {
  [ "${LITFOW_DEBUG:-0}" = "1" ] || return 0
  printf '%s %s\n' "$(litfow_now)" "$*" >>"$LITFOW_STATE_DIR/debug.log" 2>/dev/null || true
}

# --- Per-session hook-call log (hooks/<session_id>.jsonl) -------------------
#
# What it literally is: the log of every call Claude Code makes to our hooks.
# hook.sh is wired to every lifecycle event and appends one line per hook call.
# capture.sh reads it on Stop / SessionEnd / PreCompact to build contract Turns.
# Each session gets its OWN file under
# $LITFOW_STATE_DIR/hooks/, so one session's trace is `tail -f`-able on its own
# and never interleaves with concurrent sessions. ON by default; set
# LITFOW_HOOK_LOG=0 to disable. It records full prompt/answer/tool text, so it
# is strictly local — never POSTed to the backend, never written into the repo (see
# ../AGENTS.md hard rules). Append-only and unbounded: truncate a session's file
# when it grows (`: > "$(litfow_hooklog_file <session>)"`).

# Where per-session hook-call logs live.
LITFOW_HOOK_LOG_DIR="${LITFOW_HOOK_LOG_DIR:-$LITFOW_STATE_DIR/hooks}"

# True when the hook-call log is enabled (default on).
litfow_hooklog_enabled() {
  [ "${LITFOW_HOOK_LOG:-1}" = "1" ]
}

# The log file for a session id, sanitized to a safe filename. An empty or odd
# id falls back to "unknown" so a hook call is never dropped for lack of one.
litfow_hooklog_file() {
  local sid
  sid="$(printf '%s' "${1:-}" | tr -cd 'A-Za-z0-9._-' | cut -c1-128)"
  [ -n "$sid" ] || sid="unknown"
  printf '%s/%s.jsonl' "$LITFOW_HOOK_LOG_DIR" "$sid"
}

# Append one hook call {ts, session, event, payload} to that session's log file.
# $1 is the event label; $2 is the RAW hook input (any text). The target file is
# chosen from payload.session_id, so concurrent sessions never share a trace (the
# `session` field is kept too, so files stay greppable when merged). Invalid JSON
# is kept verbatim under `raw` rather than dropped; lacking a session_id it lands
# in hooks/unknown.jsonl. Never fails the caller.
#
# This runs on the tool path (every PreToolUse/PostToolUse), so it is kept lean:
# the common valid-JSON case is TWO jq invocations — one builds the wrapped line
# (which also validates: bad input yields nothing), one reads the session back
# out to pick the file — not the four the previous validate-then-rebuild used.
litfow_hooklog_append() {
  litfow_hooklog_enabled || return 0
  local event="$1" input="$2" ts line session file
  ts="$(litfow_now)"
  line="$(printf '%s' "$input" | jq -c --arg ts "$ts" --arg ev "$event" \
    '{ts:$ts, session:(.session_id // "unknown"),
      event:(if $ev != "" then $ev else (.hook_event_name // "unknown") end),
      payload:.}' 2>/dev/null)"
  if [ -z "$line" ]; then
    line="$(jq -cn --arg ts "$ts" --arg ev "${event:-unknown}" --arg raw "$input" \
      '{ts:$ts, session:"unknown",
        event:(if $ev != "" then $ev else "unknown" end), payload:{raw:$raw}}' 2>/dev/null)" \
      || return 0
  fi
  session="$(printf '%s' "$line" | jq -r '.session' 2>/dev/null)"
  file="$(litfow_hooklog_file "$session")"
  mkdir -p "$LITFOW_HOOK_LOG_DIR"
  printf '%s\n' "$line" >>"$file" 2>/dev/null || true
}

# POST a JSON body (read from stdin) to the backend path in $1. Return code tells
# the caller whether a retry can help:
#   0  — accepted (HTTP 2xx).
#   2  — TERMINAL rejection (HTTP 4xx, e.g. a contract mismatch). Retrying the
#        same body can never succeed, so the caller records it and moves on.
#   1  — transient failure (network error or HTTP 5xx). The caller retries on the
#        next firing.
# Overridable via LITFOW_POST_CMD (the self-test stubs the backend); the stub's
# own exit code is passed through, so a stub can exit 2 to simulate a 4xx.
litfow_post() {
  local path="$1"
  if [ -n "${LITFOW_POST_CMD:-}" ]; then
    "$LITFOW_POST_CMD" "$path"
    return $?
  fi
  local code
  code="$(curl -sS -m "$LITFOW_HTTP_TIMEOUT" -o /dev/null -w '%{http_code}' \
    -H 'content-type: application/json' \
    --data-binary @- \
    "${LITFOW_BACKEND_URL}${path}" 2>/dev/null)" || return 1
  case "$code" in
    2*) return 0 ;;
    4*) return 2 ;;
    *) return 1 ;;
  esac
}

# GET the backend path in $1 and print the response body to stdout. Returns
# non-zero on a transport error or any non-2xx, so a reader can fail soft — a
# user-facing view must never block or error a session. Overridable via
# LITFOW_GET_CMD (the self-test stubs the backend).
litfow_get() {
  local path="$1"
  if [ -n "${LITFOW_GET_CMD:-}" ]; then
    "$LITFOW_GET_CMD" "$path"
    return $?
  fi
  local out code body
  out="$(curl -sS -m "$LITFOW_HTTP_TIMEOUT" -H 'accept: application/json' \
    -w '\n%{http_code}' "${LITFOW_BACKEND_URL}${path}" 2>/dev/null)" || return 1
  code="${out##*$'\n'}"
  body="${out%$'\n'*}"
  case "$code" in
    2*) printf '%s' "$body" ;;
    *) return 1 ;;
  esac
}

# sync test marker f4c396c61
