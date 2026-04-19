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
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Resolve srectl CLI
if command -v uv &>/dev/null; then
  SRECTL="uv run --project $ROOT_DIR/srectl srectl"
else
  SRECTL="srectl"
fi

# Pre-resolve endpoint + token if not already cached
if [ -z "${SRE_AGENT_ENDPOINT:-}" ]; then
  export SRE_AGENT_ENDPOINT=$(azd env get-value SRE_AGENT_ENDPOINT 2>/dev/null || echo "")
fi
if [ -z "${SRE_AGENT_TOKEN:-}" ]; then
  export SRE_AGENT_TOKEN=$(az account get-access-token --resource https://azuresre.ai --query accessToken -o tsv 2>/dev/null || echo "")
fi

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

# ── Disable tools ────────────────────────────────────────────────────────────
echo "🗑️  Disabling tools..."
RG_SREAGENT=$(azd env get-value SREAGENT_RESOURCE_GROUP 2>/dev/null || echo "rg-isucon13-sreagent")
SUBSCRIPTION_ID=$(az account show --query id -o tsv 2>/dev/null)
ARM_AGENT_NAME=$(az resource list -g "$RG_SREAGENT" --resource-type "Microsoft.App/agents" --query "[0].name" -o tsv 2>/dev/null || echo "")
if [ -n "$ARM_AGENT_NAME" ]; then
  AGENT_RESOURCE_ID="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RG_SREAGENT}/providers/Microsoft.App/agents/${ARM_AGENT_NAME}"
  az rest --method PATCH \
    --url "https://management.azure.com${AGENT_RESOURCE_ID}?api-version=2025-05-01-preview" \
    --body '{"properties":{"experimentalSettings":{"EnableWorkspaceTools":false}}}' \
    --output none 2>/dev/null && echo "   ✅ Tools disabled" \
    || echo "   ⚠️  Could not disable tools"
fi

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
