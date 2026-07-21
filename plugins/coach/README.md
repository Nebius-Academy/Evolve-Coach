# claude-plugin

Claude Code plugin — the first LITFOW surface. In the flow of work it captures each **turn** — one genuine human request and everything the AI said and did in response — from the session's hook-call log, and sends it to the **backend**, which stores it.

Capture is **hook-first** (see [ADR-0004](../../docs/adr/0004-turn-capture.md)): the hooks are a documented, versioned vendor contract, so they are the source of truth. The session transcript — which the vendor calls an internal format that changes between releases — is read only as a **fallback** for the fields hooks don't reliably give (`model`, and the boolean `thinking` flag — whether the turn emitted thinking; the content itself is deliberately not captured); see [ADR-0004](../../docs/adr/0004-turn-capture.md).

This README covers **developing and running** the plugin; end-user install is org-managed ([`DISTRIBUTION.md`](DISTRIBUTION.md)).

## Requirements

- **macOS** (the only platform we test this PoC on).
- **bash**, **[`jq`](https://jqlang.github.io/jq/)** and **curl** on `PATH` (`brew install jq`). Hooks shell out to them; without `jq` they no-op.
- A reachable **backend**. Defaults to the deployed stand — nothing to run. For local dev, start one on `:8787` and set `LITFOW_BACKEND_URL` (see [Development](#development-local-checkout)).

## Development (local checkout)

Run from a checkout against a local backend:

```sh
cd ../backend && bun run dev           # local backend on :8787
LITFOW_BACKEND_URL=http://localhost:8787 \
  claude --plugin-dir /absolute/path/to/litfow/projects/claude-plugin
```

After changing `hooks.json` or `plugin.json`, run `/reload-plugins` or restart the session (script edits to `scripts/*.sh` apply on the next hook firing). No activation command — once loaded, the hooks fire on their own (see [How it works](#how-it-works)).

## How it works

```
every event                    ─▶ hook.sh      append raw payload → hooks/<session>.jsonl (local only)
SessionStart                   ─▶ hook.sh      register identity (accountUuid → personal data) → POST /identity
Stop · SessionEnd · PreCompact ─▶ capture.sh   build Turns from the log → POST /turns (detached)
```

- **Local-first.** The raw hook-call log holds full prompt/tool text and never leaves the machine; only the structured `Turn` is POSTed. The backend owns the data.
- **A turn** = one genuine human request and everything until the next one, keyed by `turn_id` (the vendor's prompt id — idempotent, safe to retry/backfill). Each turn carries an opaque `user_id` — the Claude account UUID from local config ([ADR-0002](../../docs/adr/0002-backend-stack-and-contract.md)); the personal data behind it (email, org, names) is registered once per session to `/identity`, kept off the turn.
- **Fail soft.** Backend down → the turn is kept and retried; the session never blocks.

Mechanic and invariants live in the [`capture.sh`](scripts/capture.sh) header and [ADR-0004](../../docs/adr/0004-turn-capture.md); the wire shape is [`contracts/src/turn.ts`](../../contracts/src/turn.ts).

## Where data lands

**The data lives on the backend** (it stores per-session JSONL). The plugin keeps only transient bookkeeping under `~/.claude/litfow/` (`LITFOW_STATE_DIR`) — plus the hook-call log that feeds capture:

```
~/.claude/litfow/
├── posted-turns-<session_id>    # turn_ids already sent, for dedup
├── rejected-turns-<session_id>  # turn_ids the backend rejected (4xx) — not retried
├── lock-<session_id>/           # transient: serialises concurrent capture runs
├── hooks/<session_id>.jsonl     # per-session hook-call log (local-only)
└── debug.log                    # only when LITFOW_DEBUG=1
```

`hooks/<session_id>.jsonl` is a local-only trace of every hook call in a session (prompts, tool calls + results). One file per session, never POSTed. See [Hook-call log](#hook-call-log-litfow_hook_log).

Each turn is POSTed once to `/turns` (shape: [`contracts/src/turn.ts`](../../contracts/src/turn.ts)) carrying its `user_id`; reconstruct a session by grouping on `user_id` + `session_id`, ordering by `turn_index`.

## Configuration (env vars)

| Variable | Default | Purpose |
| --- | --- | --- |
| `LITFOW_BACKEND_URL` | the deployed stand | The backend base URL. Set `http://localhost:8787` for local dev. |
| `LITFOW_SURFACE` | `claude-code` | Surface id sent on every turn. |
| `LITFOW_SURFACE_VERSION` | package.json `version` | Surface version sent on every turn. |
| `LITFOW_HTTP_TIMEOUT` | `5` | Seconds before a POST to the backend times out. |
| `LITFOW_STATE_DIR` | `~/.claude/litfow` | Where the plugin's bookkeeping and hook-call log are written. |
| `LITFOW_DISABLED` | `0` | Set `1` to disable all backend capture. |
| `LITFOW_TURNS` | `1` | Turn capture (`capture.sh` → `/turns`). Set `0` to disable. |
| `LITFOW_HOOK_LOG` | `1` | The hook-call log (and a full local trace). On by default; `0` disables it **and** capture. Local-only, never POSTed. |
| `LITFOW_EXTRACT_SYNC` | `0` | Set `1` to run `capture.sh` inline instead of detached (used by the self-test). |
| `LITFOW_DEBUG` | `0` | Set `1` to append a metadata line per capture run to `~/.claude/litfow/debug.log` (no prompt/answer text). |

## Debugging (where's the log?)

Set `LITFOW_DEBUG=1` and `capture.sh` appends one line per posted/failed turn to **`~/.claude/litfow/debug.log`** (`$LITFOW_STATE_DIR/debug.log`) — e.g. `capture … posted turn=…`. Metadata only, never prompt/answer text.

```sh
LITFOW_DEBUG=1 claude --plugin-dir /absolute/path/to/litfow/projects/claude-plugin
tail -f ~/.claude/litfow/debug.log     # watch turns land
: > ~/.claude/litfow/debug.log         # truncate (it only ever appends)
```

### Hook-call log (`LITFOW_HOOK_LOG`)

The hook-call log is both what `capture.sh` reads and the way to watch *what the model actually does* — the prompt, every tool call with its `tool_input`, every `tool_response`, `MessageDisplay` text, subagents, stops. `hook.sh` appends each full payload as one JSON line to *that session's* file, **`~/.claude/litfow/hooks/<session_id>.jsonl`**. **One file per session.** On by default — `LITFOW_HOOK_LOG=0` turns it off (and disables capture, which reads it).

```sh
ls -t ~/.claude/litfow/hooks/                     # sessions, most-recent first
SID=8e983f01-…                                    # the session you want (the file's basename)
tail -f ~/.claude/litfow/hooks/$SID.jsonl | jq .  # live trace of one session
# the genuine human prompts this session (what anchors each turn):
jq -r 'select(.event=="UserPromptSubmit") | .payload.prompt' ~/.claude/litfow/hooks/$SID.jsonl
```

It stays **local** — never POSTed and never written into the repo (full prompt/answer/tool text). Only the structured `Turn` `capture.sh` derives is sent. The log grows unbounded; truncate one session with `: > ~/.claude/litfow/hooks/$SID.jsonl`.

## Testing

`bash tests/selftest.sh` — synthesises a hook-call log and asserts what `capture.sh` POSTs against a stubbed backend (no server needed). No framework; requires `jq`. CI runs it on every change to the plugin.

## Known limitations (PoC)

- macOS-only; bash + `jq` + curl assumed present. Cross-platform runtime is a later phase.
- `capture.sh` runs detached, so it adds no end-of-turn delay. The open (latest) turn lands when it's closed (next genuine prompt) or on `SessionEnd`. If the session is killed before a `SessionEnd` fires (crash, closed terminal), that last open turn is not captured.
- If the backend is unreachable (network / 5xx) the turn is kept and retried on the next firing; never blocks the session. A turn the backend *rejects* (HTTP 4xx — e.g. a contract mismatch) can't succeed on retry, so it's recorded as rejected (`rejected-turns-<session>`) and not re-POSTed. A durable cross-restart queue is deferred.
- The tool-step `decision` covers permission gates only: `allow` (a `PermissionRequest` the person granted) or `deny` (`PermissionDenied`); no key means the tool ran without asking. Finer grades (`accept_edits`, "always allow") are not distinguished yet.
- Slash commands are mined into the turn's `commands` (genuine prompts and bare invocations alike), but a bare command fired *before the first genuine prompt* of a session belongs to no turn and is dropped.
- The `Turn` ships prompt/response text and full tool I/O; a content-redaction policy is an open question (see [ADR-0004](../../docs/adr/0004-turn-capture.md)).
- `accept/modify/reject` of an AI output, an explicit user quality rating, and the user's *stated confidence* are not derivable from any source (hooks or transcript) — they need elicitation or an exercise surface, not more capture; separate decisions.
- No auth yet.

## Next

Later phases add the end-of-day feedback, auth, and a cross-platform runtime. See the [roadmap](../../docs/product/poc-roadmap.md).
