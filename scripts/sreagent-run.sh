#!/bin/bash
set -uo pipefail

# =============================================================================
# sreagent-run.sh — Create trigger, execute, and optionally watch
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

echo ""
echo "🚀 Creating and executing contest trigger..."

CONTEST_PROMPT="ISUCON の競技を開始してください。制限時間は今から60分です。その間は何回でもベンチマークを走らせて良いですが、最後に回したベンチマークのスコアがあなたの得点になります。"

# Create trigger
TRIGGER_OUTPUT=$($SRECTL trigger create --name start-contest --prompt "$CONTEST_PROMPT" --agent isucon 2>&1)
echo "$TRIGGER_OUTPUT"
TRIGGER_ID=$(echo "$TRIGGER_OUTPUT" | grep "Trigger ID:" | awk '{print $NF}')
if [ -z "$TRIGGER_ID" ]; then
  echo "❌ Could not create trigger"
  exit 1
fi
azd env set TRIGGER_ID "$TRIGGER_ID" 2>/dev/null
echo "   Saved TRIGGER_ID=$TRIGGER_ID"

# Execute trigger
EXEC_OUTPUT=$($SRECTL trigger execute "$TRIGGER_ID" 2>&1)
echo "$EXEC_OUTPUT"
THREAD_ID=$(echo "$EXEC_OUTPUT" | grep "Thread ID:" | awk '{print $NF}')
if [ -z "$THREAD_ID" ]; then
  echo "❌ Could not execute trigger"
  exit 1
fi
azd env set THREAD_ID "$THREAD_ID" 2>/dev/null
echo "   Saved THREAD_ID=$THREAD_ID"
echo ""
echo "✅ Contest started!"
echo "   Thread ID: $THREAD_ID"
echo "   Watch:     bash scripts/watch-sreagent.sh"
echo ""

# Watch if requested
if $ENABLE_WATCH; then
  exec bash "$SCRIPT_DIR/watch-sreagent.sh" --interval "$INTERVAL" "$THREAD_ID"
fi
