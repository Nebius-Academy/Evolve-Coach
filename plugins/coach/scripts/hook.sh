#!/usr/bin/env bash
# Per-event hook: append each event's full payload to the session hook-call log
# that capture.sh reads (ADR-0004). Local-only; never breaks a session (no stdout, always exits 0).

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
. "$SCRIPT_DIR/lib.sh"

EVENT="${1:-}"
INPUT="$(cat)"

litfow_hooklog_append "$EVENT" "$INPUT"

exit 0
