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
source "$SCRIPT_DIR/lib/sreagent-common.sh"

# Parse arguments
ENABLE_WATCH=false
INTERVAL=10

while [[ $# -gt 0 ]]; do
	case "$1" in
	--watch)
		ENABLE_WATCH=true
		shift
		;;
	--interval)
		INTERVAL="$2"
		shift 2
		;;
	*)
		echo "❌ Unknown argument: $1"
		exit 1
		;;
	esac
done

# Load existing IDs from azd env
TRIGGER_ID=$(azd env get-value TRIGGER_ID 2>/dev/null || echo "")
THREAD_ID=$(azd env get-value THREAD_ID 2>/dev/null || echo "")

# ── Validate stored IDs ──────────────────────────────────────────────────────
# After azd down + azd up, old IDs become stale. Detect and clear them.
if [ -n "$THREAD_ID" ]; then
	HTTP_CODE=$($SRECTL -o json thread messages "$THREAD_ID" --top 1 2>&1 | grep -o 'HTTP [0-9]*' | grep -o '[0-9]*' || echo "200")
	if [ "$HTTP_CODE" = "404" ]; then
		echo "⚠️  Stored THREAD_ID is stale (404). Clearing..."
		THREAD_ID=""
		TRIGGER_ID=""
		azd env set THREAD_ID "" 2>/dev/null
		azd env set TRIGGER_ID "" 2>/dev/null
	fi
fi

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
	CONTEST_PROMPT="競技を開始してください。制限時間は今から8時間です。最後に回したベンチマークのスコアがあなたの得点になります。"
	TRIGGER_ID=$($SRECTL -o json trigger create --name start-contest --prompt "$CONTEST_PROMPT" --agent isucon 2>/dev/null |
		python3 -c "import sys,json; print(json.load(sys.stdin).get('triggerId',''))" 2>/dev/null)
	if [ -z "$TRIGGER_ID" ]; then
		echo "❌ Could not create trigger"
		exit 1
	fi
	azd env set TRIGGER_ID "$TRIGGER_ID" 2>/dev/null
	echo "   ✅ Trigger: $TRIGGER_ID"
fi

# ── Execute trigger (if needed) ──────────────────────────────────────────────
if [ -n "$THREAD_ID" ]; then
	echo "📌 Thread already exists: $THREAD_ID"
else
	echo "🚀 Executing trigger..."
	THREAD_ID=$($SRECTL -o json trigger execute "$TRIGGER_ID" 2>/dev/null |
		python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('execution',d).get('threadId',''))" 2>/dev/null)
	if [ -z "$THREAD_ID" ]; then
		echo "❌ Could not execute trigger"
		exit 1
	fi
	azd env set THREAD_ID "$THREAD_ID" 2>/dev/null
	echo "   ✅ Thread:  $THREAD_ID"
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
