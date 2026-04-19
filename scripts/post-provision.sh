#!/bin/bash
set -uo pipefail

# =============================================================================
# post-provision.sh — azd postprovision hook entrypoint
#
# Configures the SRE Agent with memory, MCP connector, skills, and agents
# based on the AGENT_TIER setting (L100-L400).
#
# Usage: bash scripts/post-provision.sh
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SRECTL="python3 $SCRIPT_DIR/srectl.py"

AGENT_TIER=$(azd env get-value AGENT_TIER 2>/dev/null || echo "L100")
ALL_TIERS=(L100 L200 L300 L400)

echo ""
echo "============================================="
echo "  SRE Agent — Configuration (${AGENT_TIER})"
echo "============================================="
echo ""

# ── Memory add ─────────────────────────────────────────────────────────────────
echo "📚 Adding memory files..."
MEMORY_FILES=("$ROOT_DIR"/sre-config/base/memory/*.md)
if [ ${#MEMORY_FILES[@]} -gt 0 ] && [ -f "${MEMORY_FILES[0]}" ]; then
  $SRECTL memory add "${MEMORY_FILES[@]}"
fi
echo ""

# ── MCP connector ────────────────────────────────────────────────────────────
echo "🔗 Creating MCP connector..."
MCP_FQDN=$(azd env get-value ISUCON_MCP_FQDN 2>/dev/null || echo "")
MCP_API_KEY=$(azd env get-value ISUCON_MCP_API_KEY 2>/dev/null || echo "")
if [ -n "$MCP_FQDN" ] && [ -n "$MCP_API_KEY" ]; then
  $SRECTL mcp add --name isucon-mcp --url "https://${MCP_FQDN}/mcp" --header "X-API-Key=${MCP_API_KEY}"
else
  echo "   ⚠️  ISUCON_MCP_FQDN or ISUCON_MCP_API_KEY not set (existing connector may still work)"
fi
echo ""

# ── Skills (cumulative) ─────────────────────────────────────────────────────
echo "🧠 Deploying skills..."
# Base skills (always)
for skill_dir in "$ROOT_DIR"/sre-config/base/skills/*/; do
  [ -d "$skill_dir" ] || continue
  $SRECTL skill add --dir "$skill_dir"
done

# Tier-specific skills (cumulative)
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

# ── Agents ───────────────────────────────────────────────────────────────────
echo "🤖 Creating agents (${AGENT_TIER})..."
for yaml_file in "$ROOT_DIR/sre-config/${AGENT_TIER}/agents/"*.yaml; do
  [ -f "$yaml_file" ] || continue
  $SRECTL agent add -f "$yaml_file"
done
echo ""

# ── Cleanup (downgrade) ─────────────────────────────────────────────────────
echo "🧹 Cleaning up inactive tiers..."
found=false
for tier in "${ALL_TIERS[@]}"; do
  [ "$tier" = "$AGENT_TIER" ] && found=true && continue
  $found || continue

  # Delete skills from higher tiers
  tier_skills="$ROOT_DIR/sre-config/${tier}/skills"
  if [ -d "$tier_skills" ]; then
    for skill_dir in "${tier_skills}"/*/; do
      [ -d "$skill_dir" ] || continue
      skill_name=$(basename "$skill_dir")
      $SRECTL skill delete "$skill_name" 2>/dev/null
    done
  fi

  # Delete agents only in higher tiers that aren't in current tier
  for yaml_file in "$ROOT_DIR/sre-config/${tier}/agents/"*.yaml; do
    [ -f "$yaml_file" ] || continue
    agent_name=$(python3 -c "
import re, sys
with open(sys.argv[1]) as f:
    for line in f:
        m = re.match(r'^name:\s*(.*)', line)
        if m: print(m.group(1).strip()); break
" "$yaml_file" 2>/dev/null)
    [ -z "$agent_name" ] && continue
    # Check if this agent exists in the current tier
    exists=false
    for active in "$ROOT_DIR/sre-config/${AGENT_TIER}/agents/"*.yaml; do
      [ -f "$active" ] || continue
      active_name=$(python3 -c "
import re, sys
with open(sys.argv[1]) as f:
    for line in f:
        m = re.match(r'^name:\s*(.*)', line)
        if m: print(m.group(1).strip()); break
" "$active" 2>/dev/null)
      [ "$agent_name" = "$active_name" ] && exists=true && break
    done
    $exists || $SRECTL agent delete "$agent_name" 2>/dev/null
  done
done
echo ""

# ── Enable experimental tools ────────────────────────────────────────────────
echo "⚙️  Enabling workspace tools..."
RG_SREAGENT=$(azd env get-value SREAGENT_RESOURCE_GROUP 2>/dev/null || echo "rg-isucon13-sreagent")
SUBSCRIPTION_ID=$(az account show --query id -o tsv 2>/dev/null)
AGENT_NAME=$(az resource list -g "$RG_SREAGENT" --resource-type "Microsoft.App/agents" --query "[0].name" -o tsv 2>/dev/null || echo "")
AGENT_RESOURCE_ID="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RG_SREAGENT}/providers/Microsoft.App/agents/${AGENT_NAME}"
az rest --method PATCH \
  --url "https://management.azure.com${AGENT_RESOURCE_ID}?api-version=2025-05-01-preview" \
  --body '{"properties":{"experimentalSettings":{"EnableWorkspaceTools":true}}}' \
  --output none 2>/dev/null && echo "   ✅ Workspace tools enabled" \
  || echo "   ⚠️  Could not enable tools"
echo ""

# ── Verify ───────────────────────────────────────────────────────────────────
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
