#!/usr/bin/env bash
# LITFOW — hook-first turn capture (see ../../docs/adr/0004-turn-capture.md).
#
# The single capture path (superseding the old transcript extractor and the
# metadata-only event stream — see the ADR).
# Triggered on Stop / SessionEnd / PreCompact. Reads THIS session's hook-call log
# ($LITFOW_STATE_DIR/hooks/<session>.jsonl — full payloads, in order, written by
# hook.sh) and builds contract `Turn`s, then POSTs each to /turns.
#
# A Turn is one GENUINE human request and everything the AI said/did until the
# next genuine request (across any number of Stops). System injections
# (<task-notification>, wrapper-only prompts) never start a turn; a
# <task-notification> folds in as a `subagent_result` segment; a bare slash
# command (wrappers only) starts no turn but its name is mined into the
# enclosing turn's `commands`. Keyed by `turn_id` (the genuine prompt's vendor
# id). effort / duration_ms / permission decision (allow AND deny — absent
# means the tool ran without a gate) / sub-agent id ride the tool step they
# describe — no second stream. `session_source` (SessionStart's source:
# startup/resume/clear/compact) is stamped on every turn for lineage.
#
# The transcript (an internal, unstable format) is read ONLY as a fallback for
# `model` and the `thinking` flag (did this turn emit thinking blocks —
# content is deliberately not captured), index-zipped to the hook turns; if
# it's missing both are omitted and capture still succeeds (ADR-0004).
#
# The OPEN (latest) turn is posted as soon as it is genuinely FINISHED — it
# reached a terminal Stop (end_reason completed/error, not still mid-flight) AND
# has no background work still outstanding (a background sub-agent / Bash whose
# <task-notification> result would still fold into this same turn). So a completed
# turn ships on its own Stop, without waiting for the next prompt — yet a mid-turn
# background round-trip is never captured half-finished. SessionEnd releases the
# open turn regardless. Dedup by turn_id (posted-turns-<session>) makes
# re-firing / backfill safe. Runs DETACHED by default (LITFOW_EXTRACT_SYNC=1
# forces inline, for the self-test). Never exits non-zero on a normal path.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
. "$SCRIPT_DIR/lib.sh"

# Build the turns array from the slurped hook-call log ($L). See the module
# header. null-valued optional keys are dropped (the contract rejects null).
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

LITFOW_CAPTURE_FILTER="$LITFOW_CLEAN_DEF"'
  # Flatten the hook effort ({level} object or a bare string).
  def eff(p): (p.effort) as $e | if ($e|type)=="object" then $e.level else $e end;
  # A tool_response flattened to text (string as-is, else JSON).
  def tout(r): if r==null then null elif (r|type)=="string" then r else (r|tojson) end;
  # A hook line is a genuine human prompt when UserPromptSubmit cleans to non-empty.
  def is_genuine: .event=="UserPromptSubmit" and ((clean(.payload.prompt)|length)>0);
  # A synthetic prompt that is a folded sub-agent result.
  def is_tasknotif: .event=="UserPromptSubmit"
    and ((clean(.payload.prompt)|length)==0)
    and (((.payload.prompt // "")|test("<task-notification>")));

  . as $L | ($L|length) as $n
  | ([$L[]|select(.event=="PostToolUseFailure")|.payload.tool_use_id]|map(select(.!=null))) as $failed
  # A permission gate leaves a decision on the step: PermissionRequest marks the
  # ask (allow, if the tool then ran), PermissionDenied overrides to deny (the
  # right-biased + below). No gate → no decision key at all.
  | ([$L[]|select(.event=="PermissionRequest")|{key:(.payload.tool_use_id//"_none"),value:"allow"}]|from_entries) as $asked
  | ([$L[]|select(.event=="PermissionDenied")|{key:(.payload.tool_use_id//"_none"),value:"deny"}]|from_entries) as $denied
  | ($asked + $denied) as $decisions
  | ([$L[]|select(.event=="SessionStart")|.payload.source]|map(select(.!=null and .!=""))|last) as $source
  | ([range(0;$n)|select($L[.]|is_genuine)]) as $P
  | [ range(0;($P|length)) as $k
      | $P[$k] as $i
      | (if ($k+1) < ($P|length) then $P[$k+1] else $n end) as $j
      | $L[$i] as $pm
      | ($L[$i:$j]) as $span
      | {
          turn_id: ($pm.payload.prompt_id // ("idx-"+($i|tostring))),
          turn_index: $k,
          started_at: ($pm.ts // null),
          ended_at: ([$span[]|select(.event=="Stop")|.ts]|last),
          # Why the turn ended, from its terminal lifecycle event. We look at the
          # LAST Stop/StopFailure, not merely "is there a Stop" — a sub-agent
          # round-trip fires an intermediate Stop mid-turn, so a turn interrupted
          # AFTER that Stop still ends with trailing work. $lt = index of the last
          # terminal event in the span; $la = index of the last assistant work
          # (MessageDisplay/PostToolUse).
          end_reason: (
            ([range(0;($span|length))|select(($span[.].event=="Stop") or ($span[.].event=="StopFailure"))]|last) as $lt
            | ([range(0;($span|length))|select((($span[.].event=="MessageDisplay") and ((($span[.].payload.delta // "")|length)>0)) or ($span[.].event=="PostToolUse"))]|last) as $la
            | if $lt==null then "interrupted"
              elif ($span[$lt].event=="StopFailure") then "error"
              elif ($la!=null and ($la>$lt)) then "interrupted"
              else "completed" end
          ),
          # Background work still in flight within this span: a background
          # sub-agent / Bash launched but not yet finished, whose result will
          # still fold into THIS turn via a later <task-notification>. While it is
          # >0 the open turn is held (a final answer here would be premature).
          # Used ONLY for that hold decision — stripped before POST (the contract
          # has no such field). start-like minus stop-like lifecycle events.
          outstanding: (
            ([$span[]|select(.event=="SubagentStart" or .event=="TaskCreated")]|length)
            - ([$span[]|select(.event=="SubagentStop" or .event=="TaskCompleted")]|length)
          ),
          cwd: ($pm.payload.cwd // null),
          session_source: $source,
          # Slash commands in this span — the genuine prompt itself plus any bare
          # invocations after it (they clean to empty, so they start no turn).
          commands: (
            ([$span[]|select(.event=="UserPromptSubmit")
              |((.payload.prompt // "")|capture("<command-name>(?<c>[\\s\\S]*?)</command-name>").c)
              |gsub("^[\\s]+";"")|gsub("[\\s]+$";"")|select(length>0)]) as $c
            | if ($c|length)>0 then $c else null end),
          prompt: { text: (clean($pm.payload.prompt)) },
          assistant_messages: [ $span[]
            | if (.event=="MessageDisplay" and (((.payload.delta // "")|length)>0))
                then {type:"text", text:(.payload.delta)}
              elif .event=="PostToolUse"
                then ( .payload as $p
                  | {type:"tool_step", tool_name:($p.tool_name // "?")}
                    + (if ($p.tool_use_id!=null) then {tool_use_id:$p.tool_use_id} else {} end)
                    + (if ($p.tool_input!=null) then {tool_input:$p.tool_input} else {} end)
                    + (tout($p.tool_response) as $o | if ($o!=null and (($o|length)>0)) then {tool_output:$o} else {} end)
                    + (if ($p.tool_use_id!=null and (($failed|index($p.tool_use_id))!=null)) then {is_error:true} else {} end)
                    + (if ($p.duration_ms|type)=="number" then {duration_ms:$p.duration_ms} else {} end)
                    + (eff($p) as $e | if ($e!=null and $e!="") then {effort:($e|tostring)} else {} end)
                    + (if ($p.permission_mode!=null and $p.permission_mode!="") then {permission_mode:$p.permission_mode} else {} end)
                    + (($decisions[$p.tool_use_id // "_none"]) as $d | if $d!=null then {decision:$d} else {} end)
                    + (if ($p.agent_id!=null and $p.agent_id!="") then {agent_id:$p.agent_id} else {} end)
                    + (if ($p.agent_type!=null and $p.agent_type!="") then {agent_type:$p.agent_type} else {} end) )
              elif is_tasknotif
                then ( (.payload.prompt // "") as $pp
                  | {type:"subagent_result",
                     text: (if ($pp|test("<result>")) then ($pp|capture("<result>(?<r>[\\s\\S]*?)</result>").r) else $pp end)}
                    + (if ($pp|test("Agent \"")) then {agent_type:($pp|capture("Agent \"(?<a>[^\"]+)\"").a)} else {} end) )
              else empty end ],
          last_assistant_message: ([$span[]|select(.event=="Stop")|.payload.last_assistant_message]|map(select(.!=null and .!=""))|last // "")
        }
      | with_entries(select(.value!=null))
    ]'

# Fallback fields from the transcript ($all): the {model, thinking} of each
# GENUINE transcript prompt, in order — index-zipped to the hook turns. Uses the
# same wrapper-cleaning so a <task-notification> is not counted as a prompt and
# the indices align with the hook side. model + the thinking flag are the ONLY
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

run_capture() {
  local INPUT="$1"
  [ "${LITFOW_DISABLED:-0}" = "1" ] && return 0
  [ "${LITFOW_TURNS:-1}" = "1" ] || return 0

  local SESSION_ID EVENT LOG TRANSCRIPT
  SESSION_ID="$(jq -r '.session_id // "unknown"' <<<"$INPUT")"
  EVENT="$(jq -r '.hook_event_name // ""' <<<"$INPUT")"
  TRANSCRIPT="$(jq -r '.transcript_path // ""' <<<"$INPUT")"
  litfow_init_dirs
  LOG="$(litfow_hooklog_file "$SESSION_ID")"
  [ -f "$LOG" ] || { litfow_debug "capture session=$SESSION_ID no-hooklog"; return 0; }

  # Serialise concurrent detached runs for this session. Stop and SessionEnd can
  # fire close together and both run detached, and the check-then-append dedup
  # below is not atomic — two runs could each see a turn un-posted and both POST
  # it (the backend appends, so that dups a row). A per-session lock closes the window:
  # a non-SessionEnd firing that loses the race just skips (another firing covers
  # those turns), but SessionEnd MUST run (it releases the open turn), so it waits.
  local LOCK LOCK_WAIT tries
  LOCK="$LITFOW_STATE_DIR/lock-$(printf '%s' "$SESSION_ID" | tr -cd 'A-Za-z0-9._-' | cut -c1-128)"
  LOCK_WAIT=1; [ "$EVENT" = "SessionEnd" ] && LOCK_WAIT=500
  tries=0
  while ! mkdir "$LOCK" 2>/dev/null; do
    # Reclaim a lock left behind by a killed run (older than ~2 min).
    if [ -n "$(find "$LOCK" -prune -mmin +2 2>/dev/null)" ]; then
      rmdir "$LOCK" 2>/dev/null || true; continue
    fi
    tries=$((tries + 1))
    [ "$tries" -ge "$LOCK_WAIT" ] && { litfow_debug "capture session=$SESSION_ID lock-held event=$EVENT"; return 0; }
    sleep 0.1
  done
  # Released on exit. LITFOW_LOCKDIR is global on purpose: a `local` would be out
  # of scope when the EXIT trap fires after the function returns.
  LITFOW_LOCKDIR="$LOCK"
  trap 'rmdir "${LITFOW_LOCKDIR:-}" 2>/dev/null || true' EXIT

  # Base turns from the hook-call log.
  local BASE
  BASE="$(jq -s "$LITFOW_CAPTURE_FILTER" "$LOG" 2>/dev/null)"
  [ -n "$BASE" ] && [ "$BASE" != "null" ] || return 0

  # Fallback: model from the transcript, merged by index.
  local TR="[]"
  if [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
    TR="$(jq -s "$LITFOW_TRANSCRIPT_FALLBACK" "$TRANSCRIPT" 2>/dev/null || echo '[]')"
    [ -n "$TR" ] || TR="[]"
  fi
  # Merge the (small) transcript fallback into the (potentially large) base
  # array. BASE rides stdin — a real session's turns can be hundreds of KB, past
  # the CLI arg-length limit; only the tiny TR is passed as an argument.
  local TURNS
  TURNS="$(printf '%s' "$BASE" | jq -c --argjson tr "$TR" '
    [ range(0;length) as $k
      | .[$k]
        + ( ($tr[$k] // {}) as $t
            | (if ($t.model // null)!=null then {model:$t.model} else {} end)
              # thinking is stamped true/false whenever the transcript segment
              # exists; absent = unknown (no transcript was read).
              + (if ($t|has("thinking")) then {thinking:$t.thinking} else {} end) ) ]' 2>/dev/null)"
  [ -n "$TURNS" ] && [ "$TURNS" != "null" ] || return 0

  local USER_ID POSTED REJECTED count i
  USER_ID="$(litfow_user_id)"
  POSTED="$LITFOW_STATE_DIR/posted-turns-$SESSION_ID"
  # Turns the backend rejected with a 4xx (a retry can't succeed) — recorded so
  # they are not re-POSTed on every firing.
  REJECTED="$LITFOW_STATE_DIR/rejected-turns-$SESSION_ID"
  count="$(jq 'length' <<<"$TURNS" 2>/dev/null || echo 0)"

  i=0
  while [ "$i" -lt "$count" ]; do
    local turn pid is_last complete payload rc
    turn="$(jq -c ".[$i]" <<<"$TURNS")"
    is_last=$([ "$((i + 1))" -eq "$count" ] && echo 1 || echo 0)
    i=$((i + 1))
    # The open (latest) turn is posted as soon as it is genuinely finished:
    # it reached a terminal Stop (end_reason completed/error — not still
    # mid-flight) AND has no background work still outstanding (which would fold
    # in via a later <task-notification>). Otherwise it is held for the next
    # firing. SessionEnd releases it regardless (no continuation is coming).
    if [ "$is_last" = "1" ] && [ "$EVENT" != "SessionEnd" ]; then
      local er outstanding
      er="$(jq -r '.end_reason // ""' <<<"$turn" 2>/dev/null)"
      outstanding="$(jq -r '.outstanding // 0' <<<"$turn" 2>/dev/null)"
      case "$er" in completed | error) ;; *) continue ;; esac
      [ "${outstanding:-0}" -gt 0 ] 2>/dev/null && continue
    fi
    # A turn is worth posting once it has any process or a final answer.
    complete="$(jq -r '((.assistant_messages|length)>0) or ((.last_assistant_message|length)>0)' <<<"$turn" 2>/dev/null)"
    [ "$complete" = "true" ] || continue
    pid="$(jq -r '.turn_id // ""' <<<"$turn")"
    [ -n "$pid" ] || continue
    if [ -f "$POSTED" ] && grep -qxF "$pid" "$POSTED"; then continue; fi
    if [ -f "$REJECTED" ] && grep -qxF "$pid" "$REJECTED"; then continue; fi

    # The turn rides stdin (uncapped tool output can make one turn large, past
    # the CLI arg-length limit); only small scalars are passed as arguments.
    payload="$(printf '%s' "$turn" | jq -c \
      --arg sid "$SESSION_ID" --arg uid "$USER_ID" --arg ts "$(litfow_now)" \
      --arg surface "$LITFOW_SURFACE" --arg ver "$LITFOW_SURFACE_VERSION" \
      'del(.outstanding)
       + {session_id:$sid, captured_at:$ts}
       + (if $uid != "" then {user_id:$uid} else {} end)
       + {surface: ({id:$surface} + (if $ver=="" then {} else {version:$ver} end))}')"

    # litfow_post returns 0 on 2xx, 2 on a 4xx (terminal — do not retry), and
    # anything else on a network / 5xx failure (kept for the next firing).
    printf '%s' "$payload" | litfow_post /turns >/dev/null 2>&1
    rc=$?
    if [ "$rc" -eq 0 ]; then
      echo "$pid" >>"$POSTED"
      litfow_debug "capture session=$SESSION_ID posted turn=$pid"
    elif [ "$rc" -eq 2 ]; then
      echo "$pid" >>"$REJECTED"
      litfow_debug "capture session=$SESSION_ID rejected turn=$pid (4xx, not retried)"
    else
      litfow_debug "capture session=$SESSION_ID post-failed turn=$pid (will retry)"
    fi
  done
}

INPUT="$(cat)"
if [ "${LITFOW_EXTRACT_SYNC:-0}" = "1" ]; then
  run_capture "$INPUT"
else
  (run_capture "$INPUT") >/dev/null 2>&1 &
  disown 2>/dev/null || true
fi
exit 0
