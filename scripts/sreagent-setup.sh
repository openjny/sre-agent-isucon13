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
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ALL_TIERS=(L100 L200 L300 L400)

# Resolve srectl CLI
if command -v uv &>/dev/null; then
  SRECTL="uv run --project $ROOT_DIR/srectl srectl"
else
  pip install -q -e "$ROOT_DIR/srectl" 2>/dev/null
  SRECTL="srectl"
fi

# Parse arguments
AGENT_TIER=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    L[1-4]00) AGENT_TIER="$1"; shift ;;
    *) echo "❌ Unknown argument: $1"; exit 1 ;;
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

# ── Pre-resolve endpoint + token (cache for all srectl invocations) ──────────
export SRE_AGENT_ENDPOINT=$(azd env get-value SRE_AGENT_ENDPOINT 2>/dev/null || echo "")
export SRE_AGENT_TOKEN=$(az account get-access-token --resource https://azuresre.ai --query accessToken -o tsv 2>/dev/null || echo "")

echo ""
echo "============================================="
echo "  SRE Agent — Setup (${AGENT_TIER})"
echo "============================================="
echo ""

# ── Clear existing configuration ────────────────────────────────────────────
bash "$SCRIPT_DIR/sreagent-clear.sh"
echo ""

# Helper: extract agent name from YAML (supports both v2 and legacy)
agent_name_from_yaml() {
  python3 -c "
import yaml, sys
with open(sys.argv[1]) as f:
    spec = yaml.safe_load(f)
if 'metadata' in spec:
    print(spec['metadata'].get('name', ''))
else:
    print(spec.get('name', ''))
" "$1" 2>/dev/null
}

# ── Memory ───────────────────────────────────────────────────────────────────
echo "📚 Adding memory files..."
MEMORY_FILES=("$ROOT_DIR"/sre-config/base/memory/*.md)
if [ ${#MEMORY_FILES[@]} -gt 0 ] && [ -f "${MEMORY_FILES[0]}" ]; then
  $SRECTL memory add "${MEMORY_FILES[@]}"
fi
echo ""

# ── Enable tools (must precede agent creation) ──────────────────────────────
echo "⚙️  Enabling tools..."
RG_SREAGENT=$(azd env get-value SREAGENT_RESOURCE_GROUP 2>/dev/null || echo "rg-isucon13-sreagent")
SUBSCRIPTION_ID=$(az account show --query id -o tsv 2>/dev/null)
ARM_AGENT_NAME=$(az resource list -g "$RG_SREAGENT" --resource-type "Microsoft.App/agents" --query "[0].name" -o tsv 2>/dev/null || echo "")
AGENT_RESOURCE_ID="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RG_SREAGENT}/providers/Microsoft.App/agents/${ARM_AGENT_NAME}"
az rest --method PATCH \
  --url "https://management.azure.com${AGENT_RESOURCE_ID}?api-version=2025-05-01-preview" \
  --body '{"properties":{"experimentalSettings":{"EnableWorkspaceTools":true}}}' \
  --output none 2>/dev/null && echo "   ✅ Tools enabled" \
  || echo "   ⚠️  Could not enable tools"
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
  tmp_yaml=$(mktemp)
  python3 -c "
import yaml, sys
with open(sys.argv[1]) as f:
    spec = yaml.safe_load(f)
if 'spec' in spec and 'handoffs' in spec.get('spec', {}):
    spec['spec']['handoffs'] = []
elif 'handoffs' in spec:
    spec['handoffs'] = []
with open(sys.argv[2], 'w') as f:
    yaml.dump(spec, f, default_flow_style=False, allow_unicode=True, sort_keys=False)
" "$yaml_file" "$tmp_yaml"
  $SRECTL agent apply -f "$tmp_yaml" || true
  rm -f "$tmp_yaml"
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
$SRECTL memory list
$SRECTL connector list
echo ""
echo "============================================="
echo "  ✅ Done! (Tier: ${AGENT_TIER})"
echo "============================================="
