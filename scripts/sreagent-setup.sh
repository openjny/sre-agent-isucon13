#!/bin/bash
set -uo pipefail

# =============================================================================
# sreagent-setup.sh — Set up SRE Agent configuration for a given tier
#
# Configures memory, MCP connector, skills, agents, tools,
# creates a contest trigger, and kicks off the agent.
#
# Usage: bash scripts/sreagent-setup.sh [L100|L200|L300|L400]
#        Default tier: L100
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/sreagent-common.sh"
ALL_TIERS=(L100 L200 L300 L400)

# Parse arguments
AGENT_TIER=""

while [[ $# -gt 0 ]]; do
	case "$1" in
	L[1-4]00)
		AGENT_TIER="$1"
		shift
		;;
	*)
		echo "❌ Unknown argument: $1"
		exit 1
		;;
	esac
done

# Fallback tier
AGENT_TIER="${AGENT_TIER:-$(azd env get-value AGENT_TIER 2>/dev/null || echo "L100")}"

# Validate tier
valid=false
for t in "${ALL_TIERS[@]}"; do [ "$t" = "$AGENT_TIER" ] && valid=true; done
if ! $valid; then
	echo "❌ Invalid tier: $AGENT_TIER (must be L100|L200|L300|L400)"
	exit 1
fi

# Save to azd env
azd env set AGENT_TIER "$AGENT_TIER" 2>/dev/null

echo ""
echo "============================================="
echo "  SRE Agent — Setup (${AGENT_TIER})"
echo "============================================="
echo ""

# ── Clear existing configuration ────────────────────────────────────────────
bash "$SCRIPT_DIR/sreagent-clear.sh"
echo ""

# ── MCP connector ────────────────────────────────────────────────────────────
echo "🔗 Creating MCP connector..."
MCP_FQDN=$(azd env get-value ISUCON_MCP_FQDN 2>/dev/null || echo "")
MCP_API_KEY=$(azd env get-value ISUCON_MCP_API_KEY 2>/dev/null || echo "")
if [ -n "$MCP_FQDN" ] && [ -n "$MCP_API_KEY" ]; then
	$SRECTL mcp add --name isucon-mcp --url "https://${MCP_FQDN}/mcp" --header "X-API-Key=${MCP_API_KEY}"
else
	echo "   ⚠️  ISUCON_MCP_FQDN or ISUCON_MCP_API_KEY not set"
fi
echo ""

# ── Skills (cumulative) ─────────────────────────────────────────────────────
echo "🧠 Deploying skills..."
for skill_dir in "$ROOT_DIR"/sre-config/base/skills/*/; do
	[ -d "$skill_dir" ] || continue
	$SRECTL skill add --dir "$skill_dir"
done
for tier in "${ALL_TIERS[@]}"; do
	tier_skills="$ROOT_DIR/sre-config/${tier}/skills"
	if [ -d "$tier_skills" ]; then
		for skill_dir in "${tier_skills}"/*/; do
			[ -d "$skill_dir" ] || continue
			$SRECTL skill add --dir "$skill_dir"
		done
	fi
	[ "$tier" = "$AGENT_TIER" ] && break
done
echo ""

# ── Agents (two-pass for circular handoffs) ──────────────────────────────────
echo "🤖 Creating agents (${AGENT_TIER}) — pass 1: stubs..."
for yaml_file in "$ROOT_DIR/sre-config/${AGENT_TIER}/agents/"*.yaml; do
	[ -f "$yaml_file" ] || continue
	$SRECTL agent apply -f "$yaml_file" --strip-handoffs || true
done

echo "🤖 Creating agents (${AGENT_TIER}) — pass 2: with handoffs..."
for yaml_file in "$ROOT_DIR/sre-config/${AGENT_TIER}/agents/"*.yaml; do
	[ -f "$yaml_file" ] || continue
	$SRECTL agent apply -f "$yaml_file"
done
echo ""

# ── Status ───────────────────────────────────────────────────────────────────
echo "============================================="
echo "  📋 Status (${AGENT_TIER})"
echo "============================================="
echo ""
$SRECTL agent list
$SRECTL skill list
$SRECTL connector list
echo ""
echo "============================================="
echo "  ✅ Done! (Tier: ${AGENT_TIER})"
echo "============================================="
