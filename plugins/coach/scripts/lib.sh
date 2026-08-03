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

LITFOW_CLAUDE_CONFIG="${LITFOW_CLAUDE_CONFIG:-$HOME/.claude.json}"

# Backend base URL — defaults to public prod; point at http://localhost:8787 for local dev.
LITFOW_BACKEND_URL="${LITFOW_BACKEND_URL:-https://coach.evolve.nebius.com/api}"
# Hang guard, not an answer budget: must outlast the backend's slowest answer or it's discarded after being paid for.
LITFOW_HTTP_TIMEOUT="${LITFOW_HTTP_TIMEOUT:-25}"

# Backend credential — a per-org JWT (ADR-0002). No exp, so only a key rotation invalidates a stored token
# (the backend 401s and the command path says so); rotate via the managed env (wins — no file to touch) or by replacing the file.
LITFOW_TOKEN_FILE="${LITFOW_TOKEN_FILE:-$LITFOW_STATE_DIR/token}"
if [ -z "${LITFOW_AUTH_TOKEN:-}" ] && [ -f "$LITFOW_TOKEN_FILE" ]; then
  LITFOW_AUTH_TOKEN="$(tr -d '\r\n' <"$LITFOW_TOKEN_FILE" 2>/dev/null)"
fi
LITFOW_AUTH_TOKEN="${LITFOW_AUTH_TOKEN:-}"

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

litfow_now() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

# user_id: the Claude account UUID from local config (opaque; undocumented internal, empty if absent).
litfow_user_id() {
  local id
  id="$(jq -r '.oauthAccount.accountUuid // empty' "$LITFOW_CLAUDE_CONFIG" 2>/dev/null || true)"
  printf '%s' "$id" | tr -d '\n' | cut -c1-256
}

# One line → debug.log; "force" always writes, "debug" only when LITFOW_DEBUG=1. Never logs prompt/answer text.
litfow_log() {
  [ "$1" = "force" ] || [ "${LITFOW_DEBUG:-0}" = "1" ] || return 0
  shift
  printf '%s %s\n' "$(litfow_now)" "$*" >>"$LITFOW_STATE_DIR/debug.log" 2>/dev/null || true
}

# --- Per-session hook-call log (hooks/<session_id>.jsonl) -------------------
# One file per session (no interleaving), append-only. Full prompt/answer/tool text, so it is
# strictly local — never POSTed, never committed (../AGENTS.md). LITFOW_HOOK_LOG=0 disables it (and capture).

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

# Append one hook call {ts, session, event, payload} to its session's log file ($1 event, $2 raw input).
# File chosen from payload.session_id so sessions never interleave; invalid JSON kept under `raw`. Never fails the caller.
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

# The surface stamp every payload carries (contracts: surface.id / surface.version).
litfow_surface_json() {
  jq -cn --arg id "$LITFOW_SURFACE" --arg version "$LITFOW_SURFACE_VERSION" \
    '{id:$id} + (if $version == "" then {} else {version:$version} end)'
}

litfow_plugin_name() {
  jq -r '.name // "coach"' "${CLAUDE_PLUGIN_ROOT:-}/.claude-plugin/plugin.json" 2>/dev/null || echo coach
}

# --- Shared jq filters (capture.sh + prompt-feedback.sh) --------------------

# Shared prompt cleaner (strips IDE/command/system wrappers). Capture and the transcript fallback
# MUST use it identically — model/thinking zip onto turns by index, so any drift misaligns them.
LITFOW_CLEAN_DEF='
  def clean(t):
    (t // "")
    | gsub("<ide_opened_file>[\\s\\S]*?</ide_opened_file>";"")
    | gsub("<ide_selection>[\\s\\S]*?</ide_selection>";"")
    | gsub("<ide_diagnostics>[\\s\\S]*?</ide_diagnostics>";"")
    | gsub("<system-reminder>[\\s\\S]*?</system-reminder>";"")
    | gsub("<command-name>[\\s\\S]*?</command-name>";"")
    | gsub("<command-message>[\\s\\S]*?</command-message>";"")
    | gsub("<command-args>[\\s\\S]*?</command-args>";"")
    | gsub("<task-notification>[\\s\\S]*?</task-notification>";"")
    | gsub("^[\\s]+";"") | gsub("[\\s]+$";"");'

# {model, thinking} of each genuine transcript prompt, in order (index-aligned with the hook turns).
# model + the thinking flag are the ONLY fields read from the transcript — thinking content is left behind (ADR-0004).
LITFOW_TRANSCRIPT_FALLBACK="$LITFOW_CLEAN_DEF"'
  def ptext:
    (.message.content) as $c
    | if ($c|type)=="string" then $c else ([$c[]?|select(.type=="text")|.text]|join("\n")) end;
  def is_prompt: .type=="user" and ((.isMeta)!=true) and ((clean(ptext)|length)>0);
  . as $all | ($all|length) as $n
  | def bnd($p): ([range($p+1;$n)|select($all[.]|is_prompt)]|if length>0 then .[0] else $n end);
    ([range(0;$n)|select($all[.]|is_prompt)]) as $P
  | [ range(0;($P|length)) as $k
      | $P[$k] as $i | bnd($i) as $j
      | ($all[($i+1):$j]) as $seg
      | { model: ([$seg[]|select(.type=="assistant")|.message.model?]|map(select(.!=null))|last),
          thinking: (([$seg[]|select(.type=="assistant")
                       |.message.content[]?
                       |select(.type=="thinking" or .type=="redacted_thinking")]|length)>0) } ]'

# The one way to reach the backend ($1 method, $2 path; POST body on stdin). Returns 0 on 2xx,
# 2 on 4xx (terminal — same body never succeeds), 1 otherwise (network/5xx — retry). Stubbed via LITFOW_REQUEST_CMD.
litfow_request() {
  local method="$1" path="$2"
  if [ -n "${LITFOW_REQUEST_CMD:-}" ]; then
    "$LITFOW_REQUEST_CMD" "$method" "$path"
    return $?
  fi
  local out code cexit
  local -a auth=() send=()
  [ -n "${LITFOW_AUTH_TOKEN:-}" ] && auth=(-H "Authorization: Bearer ${LITFOW_AUTH_TOKEN}")
  [ "$method" = "POST" ] && send=(-H 'content-type: application/json' --data-binary @-)
  out="$(curl -s -m "$LITFOW_HTTP_TIMEOUT" --connect-timeout 2 -H 'accept: application/json' \
    "${auth[@]+"${auth[@]}"}" \
    "${send[@]+"${send[@]}"}" \
    -X "$method" -w '\n%{http_code}' "${LITFOW_BACKEND_URL}${path}" 2>/dev/null)"
  cexit=$?
  [ "$cexit" -ne 0 ] && return 1
  code="${out##*$'\n'}"
  case "$code" in
    2*) printf '%s' "${out%$'\n'*}"; return 0 ;;
    4*) printf '%s' "${out%$'\n'*}"; return 2 ;;
    *) return 1 ;;
  esac
}
