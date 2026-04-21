#!/bin/bash
set -uo pipefail

# =============================================================================
# sreagent-clear.sh — Delete all SRE Agent configuration
#
# Removes all agents, skills, connectors, triggers, hooks, and memory.
#
# Usage: bash scripts/sreagent-clear.sh
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/sreagent-common.sh"

echo ""
echo "============================================="
echo "  SRE Agent — Clear All Configuration"
echo "============================================="
echo ""

# ── Delete triggers ──────────────────────────────────────────────────────────
echo "🗑️  Deleting triggers..."
TRIGGERS=$($SRECTL trigger list 2>/dev/null | grep "id=" | sed 's/.*id=\([^ ]*\).*/\1/')
for tid in $TRIGGERS; do
	$SRECTL trigger delete "$tid" 2>/dev/null
done

# ── Delete hooks ─────────────────────────────────────────────────────────────
echo "🗑️  Deleting hooks..."
HOOKS=$($SRECTL hook list 2>/dev/null | awk '{print $1}' | grep -v "^(" | grep -v "^$")
for h in $HOOKS; do
	$SRECTL hook delete "$h" 2>/dev/null
done

# ── Delete agents ────────────────────────────────────────────────────────────
echo "🗑️  Deleting agents..."
AGENTS=$($SRECTL agent list 2>/dev/null | awk '{print $1}' | grep -v "^(" | grep -v "^$")
for a in $AGENTS; do
	$SRECTL agent delete "$a" 2>/dev/null
done

# ── Delete skills ────────────────────────────────────────────────────────────
echo "🗑️  Deleting skills..."
SKILLS=$($SRECTL skill list 2>/dev/null | awk '{print $1}' | grep -v "^(" | grep -v "^$")
for s in $SKILLS; do
	$SRECTL skill delete "$s" 2>/dev/null
done

# ── Delete connectors (MCP etc.) ─────────────────────────────────────────────
echo "🗑️  Deleting connectors..."
CONNECTORS=$($SRECTL connector list 2>/dev/null | awk '{print $1}' | grep -v "^(" | grep -v "^$")
for c in $CONNECTORS; do
	$SRECTL connector delete "$c" 2>/dev/null
done

# ── Clear azd env vars ───────────────────────────────────────────────────────
azd env set TRIGGER_ID "" 2>/dev/null
azd env set THREAD_ID "" 2>/dev/null

echo ""

# ── Verify ───────────────────────────────────────────────────────────────────
echo "📋 Remaining resources:"
$SRECTL agent list
$SRECTL skill list
$SRECTL connector list
$SRECTL trigger list

echo ""
echo "✅ Clear complete"
