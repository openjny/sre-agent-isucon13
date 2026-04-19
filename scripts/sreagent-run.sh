#!/bin/bash
set -uo pipefail

# =============================================================================
# sreagent-run.sh — Create trigger, execute, and optionally watch
#
# Idempotent: skips trigger creation if TRIGGER_ID exists,
# skips execution if THREAD_ID exists.
# With --watch: watches existing or new thread.
#
# Usage: bash scripts/sreagent-run.sh [--watch] [--interval N]
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Resolve srectl CLI
if command -v uv &>/dev/null; then
  SRECTL="uv run --project $ROOT_DIR/srectl srectl"
else
  SRECTL="srectl"
fi

# Pre-resolve endpoint + token
if [ -z "${SRE_AGENT_ENDPOINT:-}" ]; then
  export SRE_AGENT_ENDPOINT=$(azd env get-value SRE_AGENT_ENDPOINT 2>/dev/null || echo "")
fi
if [ -z "${SRE_AGENT_TOKEN:-}" ]; then
  export SRE_AGENT_TOKEN=$(az account get-access-token --resource https://azuresre.ai --query accessToken -o tsv 2>/dev/null || echo "")
fi

# Parse arguments
ENABLE_WATCH=false
INTERVAL=5

while [[ $# -gt 0 ]]; do
  case "$1" in
    --watch) ENABLE_WATCH=true; shift ;;
    --interval) INTERVAL="$2"; shift 2 ;;
    *) echo "❌ Unknown argument: $1"; exit 1 ;;
  esac
done

# Load existing IDs from azd env
TRIGGER_ID=$(azd env get-value TRIGGER_ID 2>/dev/null || echo "")
THREAD_ID=$(azd env get-value THREAD_ID 2>/dev/null || echo "")

# ── Watch-only mode ──────────────────────────────────────────────────────────
if $ENABLE_WATCH && [ -n "$THREAD_ID" ]; then
  echo "Watching thread $THREAD_ID (interval: ${INTERVAL}s)"
  echo "Press Ctrl+C to stop"
  echo ""
  exec $SRECTL thread watch "$THREAD_ID" --interval "$INTERVAL"
fi

echo ""

# ── Create trigger (if needed) ───────────────────────────────────────────────
if [ -n "$TRIGGER_ID" ]; then
  echo "📌 Trigger already exists: $TRIGGER_ID"
else
  echo "🚀 Creating contest trigger..."
  CONTEST_PROMPT="ISUCON の競技を開始してください。制限時間は今から60分です。その間は何回でもベンチマークを走らせて良いですが、最後に回したベンチマークのスコアがあなたの得点になります。"
  TRIGGER_OUTPUT=$($SRECTL trigger create --name start-contest --prompt "$CONTEST_PROMPT" --agent isucon 2>&1)
  echo "$TRIGGER_OUTPUT"
  TRIGGER_ID=$(echo "$TRIGGER_OUTPUT" | grep "Trigger ID:" | awk '{print $NF}')
  if [ -z "$TRIGGER_ID" ]; then
    echo "❌ Could not create trigger"
    exit 1
  fi
  azd env set TRIGGER_ID "$TRIGGER_ID" 2>/dev/null
  echo "   Saved TRIGGER_ID=$TRIGGER_ID"
fi

# ── Execute trigger (if needed) ──────────────────────────────────────────────
if [ -n "$THREAD_ID" ]; then
  echo "📌 Thread already exists: $THREAD_ID"
else
  echo "🚀 Executing trigger..."
  EXEC_OUTPUT=$($SRECTL trigger execute "$TRIGGER_ID" 2>&1)
  echo "$EXEC_OUTPUT"
  THREAD_ID=$(echo "$EXEC_OUTPUT" | grep "Thread ID:" | awk '{print $NF}')
  if [ -z "$THREAD_ID" ]; then
    echo "❌ Could not execute trigger"
    exit 1
  fi
  azd env set THREAD_ID "$THREAD_ID" 2>/dev/null
  echo "   Saved THREAD_ID=$THREAD_ID"
fi

echo ""
echo "✅ Contest ready!"
echo "   Trigger ID: $TRIGGER_ID"
echo "   Thread ID:  $THREAD_ID"
echo "   Watch:      bash scripts/sreagent-run.sh --watch"
echo ""

# Watch if requested
if $ENABLE_WATCH; then
  exec $SRECTL thread watch "$THREAD_ID" --interval "$INTERVAL"
fi
