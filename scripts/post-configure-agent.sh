#!/bin/bash
set -uo pipefail

# =============================================================================
# post-configure-agent.sh — Configure SRE Agent via REST APIs
#
# Sets up the SRE Agent with knowledge base, MCP connector, custom agents,
# and experimental tools. Can be run standalone or called from post-provision.sh.
#
# Usage: bash scripts/post-configure-agent.sh
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$(cd "$SCRIPT_DIR/.." && pwd)"

echo ""
echo "============================================="
echo "  SRE Agent — Configuration"
echo "============================================="
echo ""

# ── Read azd outputs ─────────────────────────────────────────────────────────
RG_SREAGENT=$(azd env get-value SREAGENT_RESOURCE_GROUP 2>/dev/null || echo "rg-isucon13-sreagent")
MCP_FQDN=$(azd env get-value SSH_MCP_SERVER_FQDN 2>/dev/null || echo "")
MCP_API_KEY=$(azd env get-value MCP_API_KEY 2>/dev/null || echo "")
SUBSCRIPTION_ID=$(az account show --query id -o tsv 2>/dev/null)

# Get agent name and endpoint from ARM
AGENT_NAME=$(az resource list -g "$RG_SREAGENT" --resource-type "Microsoft.App/agents" --query "[0].name" -o tsv 2>/dev/null || echo "")
if [ -z "$AGENT_NAME" ]; then
  echo "❌ No SRE Agent found in $RG_SREAGENT. Skipping."
  exit 0
fi

AGENT_ENDPOINT=$(az resource show -g "$RG_SREAGENT" -n "$AGENT_NAME" \
  --resource-type "Microsoft.App/agents" --api-version 2025-05-01-preview \
  --query "properties.agentEndpoint" -o tsv 2>/dev/null || echo "")

AGENT_RESOURCE_ID="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RG_SREAGENT}/providers/Microsoft.App/agents/${AGENT_NAME}"
API_VERSION="2025-05-01-preview"

if [ -z "$AGENT_ENDPOINT" ]; then
  echo "❌ Could not get agent endpoint. Skipping."
  exit 0
fi

echo "📡 Agent: $AGENT_NAME"
echo "   Endpoint: $AGENT_ENDPOINT"
echo ""

# SRE Agent dataplane API requires azuresre.ai audience, NOT management.azure.com
get_token() {
  az account get-access-token --resource https://azuresre.ai --query accessToken -o tsv 2>/dev/null
}

# ── Step 1: Upload knowledge base ────────────────────────────────────────────
echo "📚 Step 1/4: Uploading knowledge base..."
TOKEN=$(get_token)

CURL_ARGS=(-s -o /dev/null -w "%{http_code}" \
  -X POST "${AGENT_ENDPOINT}/api/v1/AgentMemory/upload" \
  -H "Authorization: Bearer ${TOKEN}" \
  -F "triggerIndexing=true")

KB_COUNT=0
for f in ./sre-config/knowledge-base/*.md; do
  [ -f "$f" ] || continue
  CURL_ARGS+=(-F "files=@${f};type=text/plain")
  KB_COUNT=$((KB_COUNT + 1))
done

if [ "$KB_COUNT" -gt 0 ]; then
  HTTP_CODE=$(curl "${CURL_ARGS[@]}")
  if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "201" ]; then
    echo "   ✅ Uploaded ${KB_COUNT} files"
  else
    echo "   ⚠️  HTTP ${HTTP_CODE}"
  fi
else
  echo "   (no files found)"
fi
echo ""

# ── Step 2: Create MCP connector ─────────────────────────────────────────────
# MCP connector must be created before custom agents that reference it (mcpTools: ["ssh-mcp/*"])
echo "🔗 Step 2/4: Creating MCP connector..."
if [ -n "$MCP_FQDN" ] && [ -n "$MCP_API_KEY" ]; then
  TOKEN=$(get_token)
  # Use Mcp type with extendedProperties (not McpServer with url/headers which silently fails)
  CONNECTOR_NAME="ssh-mcp"
  CONNECTOR_JSON="{\"name\":\"${CONNECTOR_NAME}\",\"type\":\"AgentConnector\",\"properties\":{\"dataConnectorType\":\"Mcp\",\"dataSource\":\"placeholder\",\"identity\":\"\",\"extendedProperties\":{\"type\":\"http\",\"endpoint\":\"https://${MCP_FQDN}/mcp\",\"authType\":\"BearerToken\",\"bearerToken\":\"${MCP_API_KEY}\"}}}"
  http_code=$(echo "$CONNECTOR_JSON" | curl -s -o /dev/null -w "%{http_code}" \
    -X PUT "${AGENT_ENDPOINT}/api/v2/extendedAgent/connectors/${CONNECTOR_NAME}" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d @-)
  if [ "$http_code" = "200" ] || [ "$http_code" = "201" ] || [ "$http_code" = "202" ]; then
    echo "   ✅ ${CONNECTOR_NAME} → https://${MCP_FQDN}/mcp"
  else
    echo "   ⚠️  HTTP ${http_code}"
  fi
else
  echo "   ⚠️  MCP_FQDN or MCP_API_KEY not set"
fi
echo ""

# ── Step 3: Create custom agents ─────────────────────────────────────────────
echo "🤖 Step 3/4: Creating custom agents..."

for yaml_file in ./sre-config/agents/*.yaml; do
  [ -f "$yaml_file" ] || continue
  agent_name=$(python3 "$SCRIPT_DIR/yaml-to-api-json.py" "$yaml_file" --name-only 2>/dev/null)
  if [ -z "$agent_name" ]; then
    echo "   ⚠️  Could not parse: $yaml_file"
    continue
  fi

  TOKEN=$(get_token)
  json_body=$(python3 "$SCRIPT_DIR/yaml-to-api-json.py" "$yaml_file" 2>&1)

  http_code=$(echo "$json_body" | curl -s -o /dev/null -w "%{http_code}" \
    -X PUT "${AGENT_ENDPOINT}/api/v2/extendedAgent/agents/${agent_name}" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d @-)

  if [ "$http_code" = "200" ] || [ "$http_code" = "201" ] || [ "$http_code" = "202" ] || [ "$http_code" = "204" ]; then
    echo "   ✅ ${agent_name}"
  else
    echo "   ⚠️  ${agent_name}: HTTP ${http_code}"
  fi
done
echo ""

# ── Step 4: Enable experimental tools ────────────────────────────────────────
echo "⚙️  Step 4/4: Enabling tools..."

az rest --method PATCH \
  --url "https://management.azure.com${AGENT_RESOURCE_ID}?api-version=${API_VERSION}" \
  --body '{"properties":{"experimentalSettings":{"EnableWorkspaceTools":true}}}' \
  --output none 2>/dev/null && echo "   ✅ Workspace tools enabled" \
  || echo "   ⚠️  Could not enable tools"
echo ""

# ── Verify ───────────────────────────────────────────────────────────────────
echo "============================================="
echo "  📋 Status"
echo "============================================="
echo ""
TOKEN=$(get_token)

echo "  📚 Knowledge Base:"
curl -s "${AGENT_ENDPOINT}/api/v1/AgentMemory/files" -H "Authorization: Bearer ${TOKEN}" 2>/dev/null | \
  python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    for f in d.get('files',[]):
        s='✅' if f.get('isIndexed') else '⏳'
        print(f'     {s} {f[\"name\"]}')
    if not d.get('files'): print('     (none)')
except: print('     (could not retrieve)')
" 2>/dev/null
echo ""

echo "  🤖 Custom Agents:"
curl -s "${AGENT_ENDPOINT}/api/v2/extendedAgent/agents" -H "Authorization: Bearer ${TOKEN}" 2>/dev/null | \
  python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    for a in d.get('value',[]):
        t=len(a.get('properties',{}).get('tools',[]) or [])
        m=len(a.get('properties',{}).get('mcpTools',[]) or [])
        print(f'     ✅ {a[\"name\"]} ({t+m} tools)')
    if not d.get('value'): print('     (none)')
except: print('     (could not retrieve)')
" 2>/dev/null
echo ""

echo "  🔗 Connectors:"
curl -s "${AGENT_ENDPOINT}/api/v2/extendedAgent/connectors" \
  -H "Authorization: Bearer ${TOKEN}" 2>/dev/null | \
  python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    values=d.get('value', []) if isinstance(d, dict) else d
    for c in values:
        props=c.get('properties', {})
        connector_type=props.get('dataConnectorType', '?')
        source=props.get('source', '?')
        print(f'     ✅ {c[\"name\"]} ({connector_type}, source={source})')
    if not values: print('     (none)')
except: print('     (could not retrieve)')
" 2>/dev/null
echo ""

echo "============================================="
echo "  ✅ Done!"
echo "============================================="
echo ""
echo "  🤖 Portal: https://sre.azure.com"
echo "  🔧 MCP:    https://${MCP_FQDN}/mcp"
echo ""
