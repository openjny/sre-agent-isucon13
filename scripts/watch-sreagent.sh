#!/bin/bash
# =============================================================================
# watch-sreagent.sh — Watch SRE Agent contest thread messages
#
# Usage: bash scripts/watch-sreagent.sh [--interval N] [THREAD_ID]
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Resolve srectl
if command -v uv &>/dev/null; then
  SRECTL="uv run --project $ROOT_DIR/srectl srectl"
else
  SRECTL="srectl"
fi

# Parse args
INTERVAL=5
THREAD_ID=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --interval) INTERVAL="$2"; shift 2 ;;
    *) THREAD_ID="$1"; shift ;;
  esac
done

# Fallback to azd env
if [ -z "$THREAD_ID" ]; then
  THREAD_ID=$(azd env get-value THREAD_ID 2>/dev/null || echo "")
fi

if [ -z "$THREAD_ID" ]; then
  echo "❌ No thread ID. Pass as argument or set via: azd env set THREAD_ID <id>"
  exit 1
fi

echo "Watching thread: $THREAD_ID (interval: ${INTERVAL}s)"
echo "Press Ctrl+C to stop"
echo ""

exec $SRECTL thread watch "$THREAD_ID" --interval "$INTERVAL"
