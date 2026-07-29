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

# The backend base URL. Defaults to the public production backend; point at a local
# backend (http://localhost:8787) for development.
LITFOW_BACKEND_URL="${LITFOW_BACKEND_URL:-https://coach.evolve.nebius.com/api}"
# A hang guard, not an answer budget: it must outlast the slowest answer the
# backend allows itself, or that answer is thrown away after being paid for.
LITFOW_HTTP_TIMEOUT="${LITFOW_HTTP_TIMEOUT:-25}"

# Backend bearer credential: the plugin's sensitive `auth_token` config, which Claude Code
# exports to hooks as CLAUDE_PLUGIN_OPTION_AUTH_TOKEN. LITFOW_AUTH_TOKEN overrides for dev.
LITFOW_AUTH_TOKEN="${LITFOW_AUTH_TOKEN:-${CLAUDE_PLUGIN_OPTION_AUTH_TOKEN:-}}"

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
  printf '%s' "$payload" | litfow_request POST /identity >/dev/null 2>&1 || true
}

# One log line → debug.log. Level "force" always writes (a rejection stays visible
# without LITFOW_DEBUG); "debug" writes only when LITFOW_DEBUG=1. Never logs prompt/answer text.
litfow_log() {
  [ "$1" = "force" ] || [ "${LITFOW_DEBUG:-0}" = "1" ] || return 0
  shift
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

# The surface stamp every payload carries (contracts: surface.id / surface.version).
litfow_surface_json() {
  jq -cn --arg id "$LITFOW_SURFACE" --arg version "$LITFOW_SURFACE_VERSION" \
    '{id:$id} + (if $version == "" then {} else {version:$version} end)'
}

# --- Shared jq filters (capture.sh + prompt-feedback.sh) --------------------

# Shared prompt cleaner — strips IDE/command/system wrappers. Used IDENTICALLY by
# the hook-log capture pass and the transcript fallback, because model/thinking are
# zipped onto turns BY INDEX: if the two disagree on what counts as a genuine
# prompt (e.g. a prompt that is only <ide_diagnostics>), the fallback lands on the
# wrong turn. Keep them in lock-step by sharing this one definition.
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

# The {model, thinking} of each GENUINE transcript prompt, in order. capture.sh
# index-zips this onto its hook turns; prompt-feedback.sh takes the last entry
# with assistant output as the chat's mode state at submit time. Uses the same
# wrapper-cleaning so a <task-notification> is not counted as a prompt and the
# indices align with the hook side. model + the thinking flag are the ONLY
# fields we read from the transcript (ADR-0004) — thinking *content* is
# deliberately left behind.
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

# The one way to reach the backend. $1 method, $2 path; POST reads its JSON body
# from stdin. Prints the reply body on 2xx and on 4xx (the 4xx body is the backend's
# rejection reason). Returns 0 on 2xx, 2 on 4xx (terminal — same body can never
# succeed), 1 otherwise (network / 5xx — retry on the next firing). Stubbed via LITFOW_REQUEST_CMD.
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
