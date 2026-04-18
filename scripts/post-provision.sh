#!/bin/bash
set -uo pipefail

# =============================================================================
# post-provision.sh — Runs after azd provision
#
# Configures SRE Agent via dataplane REST APIs:
#   1. Upload knowledge base files
#   2. Create custom agents
#   3. Create MCP connector (SSH MCP Server)
#   4. Enable experimental tools
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$PROJECT_DIR"

echo ""
echo "============================================="
echo "  SRE Agent — Post-Provision Setup"
echo "============================================="
echo ""

# ── Read azd outputs ─────────────────────────────────────────────────────────
AGENT_ENDPOINT=$(azd env get-value SRE_AGENT_ENDPOINT 2>/dev/null || echo "")
AGENT_NAME=$(azd env get-value SRE_AGENT_NAME 2>/dev/null || echo "")
RG_SREAGENT=$(azd env get-value SREAGENT_RESOURCE_GROUP 2>/dev/null || echo "rg-isucon13-sreagent")
MCP_FQDN=$(azd env get-value SSH_MCP_SERVER_FQDN 2>/dev/null || echo "")
MCP_API_KEY=$(azd env get-value MCP_API_KEY 2>/dev/null || echo "")
SUBSCRIPTION_ID=$(az account show --query id -o tsv 2>/dev/null)

# If AGENT_ENDPOINT is empty, try to get it from the agent resource
if [ -z "$AGENT_ENDPOINT" ]; then
  AGENT_NAME=$(az resource list -g "$RG_SREAGENT" --resource-type "Microsoft.App/agents" --query "[0].name" -o tsv 2>/dev/null || echo "")
  if [ -n "$AGENT_NAME" ]; then
    AGENT_ENDPOINT=$(az resource show -g "$RG_SREAGENT" -n "$AGENT_NAME" --resource-type "Microsoft.App/agents" --api-version 2025-05-01-preview --query "properties.agentEndpoint" -o tsv 2>/dev/null || echo "")
    azd env set SRE_AGENT_ENDPOINT "$AGENT_ENDPOINT" 2>/dev/null || true
    azd env set SRE_AGENT_NAME "$AGENT_NAME" 2>/dev/null || true
  fi
fi

AGENT_RESOURCE_ID="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RG_SREAGENT}/providers/Microsoft.App/agents/${AGENT_NAME}"
API_VERSION="2025-05-01-preview"

if [ -z "$AGENT_ENDPOINT" ] || [ -z "$AGENT_NAME" ]; then
  echo "❌ Could not determine SRE Agent endpoint. Skipping agent config."
  echo "   Set up manually at https://sre.azure.com"
  exit 0
fi

echo "📡 Agent: ${AGENT_ENDPOINT}"
echo ""

# ── Helper: Get Azure AD token ───────────────────────────────────────────────
get_token() {
  az account get-access-token --resource https://management.azure.com --query accessToken -o tsv 2>/dev/null
}

# ── Step 1: Upload knowledge base files ──────────────────────────────────────
echo "📚 Step 1/4: Uploading knowledge base..."
TOKEN=$(get_token)

CURL_ARGS=(-s -o /dev/null -w "%{http_code}" \
  -X POST "${AGENT_ENDPOINT}/api/v1/AgentMemory/upload" \
  -H "Authorization: Bearer ${TOKEN}" \
  -F "triggerIndexing=true")

KB_COUNT=0
for f in ./knowledge-base/*.md; do
  CURL_ARGS+=(-F "files=@${f};type=text/plain")
  KB_COUNT=$((KB_COUNT + 1))
done

HTTP_CODE=$(curl "${CURL_ARGS[@]}")
if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "201" ]; then
  echo "   ✅ Uploaded ${KB_COUNT} knowledge base files"
else
  echo "   ⚠️  KB upload returned HTTP ${HTTP_CODE}"
fi
echo ""

# ── Step 2: Create custom agents ─────────────────────────────────────────────
echo "🤖 Step 2/4: Creating custom agents..."

for yaml_file in ./sre-config/agents/*.yaml; do
  agent_name=$(python3 -c "import yaml; print(yaml.safe_load(open('$yaml_file'))['name'])")
  TOKEN=$(get_token)

  json_body=$(python3 "$SCRIPT_DIR/yaml-to-api-json.py" "$yaml_file" 2>&1)
  if [ -z "$json_body" ] || echo "$json_body" | grep -q "^Traceback\|Error"; then
    echo "   ⚠️  ${agent_name}: YAML conversion failed"
    continue
  fi

  http_code=$(echo "$json_body" | curl -s -o /dev/null -w "%{http_code}" \
    -X PUT "${AGENT_ENDPOINT}/api/v2/extendedAgent/agents/${agent_name}" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d @-)

  if [ "$http_code" = "200" ] || [ "$http_code" = "201" ] || [ "$http_code" = "202" ] || [ "$http_code" = "204" ]; then
    echo "   ✅ Created: ${agent_name}"
  else
    echo "   ⚠️  ${agent_name} returned HTTP ${http_code}"
  fi
done
echo ""

# ── Step 3: Create MCP connector (SSH MCP Server) ───────────────────────────
echo "🔗 Step 3/4: Creating MCP connector..."

if [ -n "$MCP_FQDN" ] && [ -n "$MCP_API_KEY" ]; then
  CONNECTOR_BODY="{\"properties\":{\"dataConnectorType\":\"McpServer\",\"dataSource\":\"ssh-mcp\",\"mcpServerUrl\":\"https://${MCP_FQDN}/mcp\",\"mcpServerHeaders\":{\"Authorization\":\"Bearer ${MCP_API_KEY}\"}}}"

  RESULT=$(az rest --method PUT \
    --url "https://management.azure.com${AGENT_RESOURCE_ID}/DataConnectors/ssh-mcp?api-version=${API_VERSION}" \
    --body "$CONNECTOR_BODY" \
    -o none 2>&1 || true)

  if echo "$RESULT" | grep -qi "error"; then
    echo "   ⚠️  MCP connector: $RESULT"
  else
    echo "   ✅ MCP connector: ssh-mcp → https://${MCP_FQDN}/mcp"
  fi
else
  echo "   ⚠️  MCP_FQDN or MCP_API_KEY not set, skipping"
fi
echo ""

# ── Step 4: Enable experimental tools ────────────────────────────────────────
echo "⚙️  Step 4/4: Enabling experimental tools..."

az rest --method PATCH \
  --url "https://management.azure.com${AGENT_RESOURCE_ID}?api-version=${API_VERSION}" \
  --body '{"properties":{"experimentalSettings":{"EnableWorkspaceTools":true,"EnableDevOpsTools":true,"EnablePythonTools":true}}}' \
  --output none 2>&1 || true

echo "   ✅ Workspace, DevOps, and Python tools enabled"
echo ""

# ── Verification ─────────────────────────────────────────────────────────────
echo "============================================="
echo "  📋 Verifying setup..."
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
        t=a.get('properties',{}).get('tools',[]) or []
        m=a.get('properties',{}).get('mcpTools',[]) or []
        print(f'     ✅ {a[\"name\"]} ({len(t)+len(m)} tools)')
    if not d.get('value'): print('     (none)')
except: print('     (could not retrieve)')
" 2>/dev/null
echo ""

echo "  🔗 Connectors:"
az rest --method GET \
  --url "https://management.azure.com${AGENT_RESOURCE_ID}/DataConnectors?api-version=${API_VERSION}" \
  --query "value[].{name:name,state:properties.provisioningState}" -o json 2>/dev/null | \
  python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    for c in d:
        s='✅' if c.get('state')=='Succeeded' else '⏳ '+str(c.get('state',''))
        print(f'     {s} {c[\"name\"]}')
    if not d: print('     (none)')
except: print('     (could not retrieve)')
" 2>/dev/null
echo ""

echo "============================================="
echo "  ✅ SRE Agent Setup Complete!"
echo "============================================="
echo ""
echo "  🤖 Agent Portal:    https://sre.azure.com"
echo "  📡 Agent API:       ${AGENT_ENDPOINT}"
echo "  🔧 SSH MCP Server:  https://${MCP_FQDN}/mcp"
echo ""
echo "  👉 Try at https://sre.azure.com:"
echo "     /agent benchmark-runner"
echo "     /agent performance-investigator"
echo "     /agent code-optimizer"
echo ""
#!/bin/bash
set -euo pipefail

# Post-provision script for ISUCON13 x SRE Agent PoC
# Called by azd after infrastructure deployment.
# Configures SSH keys and SRE Agent settings.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "=== Post-provision: ISUCON13 x SRE Agent ==="

# ============================================================
# 1. Check VM provisioning status
# ============================================================

RG_SYSTEM=$(azd env get-value SYSTEM_RESOURCE_GROUP 2>/dev/null || echo "rg-isucon13-system")

echo "Checking VM provisioning status..."
for VM_NAME in vm-isucon13-contest1 vm-isucon13-contest2 vm-isucon13-contest3 vm-isucon13-bench; do
  echo -n "  $VM_NAME: "
  STATUS=$(az vm get-instance-view \
    --resource-group "$RG_SYSTEM" \
    --name "$VM_NAME" \
    --query "instanceView.extensions[?name=='CustomScript'].statuses[0].displayStatus" \
    -o tsv 2>/dev/null || echo "Unknown")
  echo "$STATUS"
done

echo ""
echo "Note: Custom Script Extension may take 15-30 minutes to complete."
echo "Check status: az vm get-instance-view -g $RG_SYSTEM -n <vm-name> --query instanceView.extensions"

# ============================================================
# 2. Display connection info
# ============================================================

echo ""
echo "=== Connection Info ==="
echo "SRE Agent Portal: https://sre.azure.com"
echo ""
echo "SSH to VMs (via Key Vault private key):"
echo "  KV_NAME=\$(az keyvault list -g $RG_SYSTEM --query '[0].name' -o tsv)"
echo "  az keyvault secret show --vault-name \$KV_NAME --name ssh-private-key --query value -o tsv > /tmp/isucon_key"
echo "  chmod 600 /tmp/isucon_key"
echo "  az vm run-command invoke -g $RG_SYSTEM -n vm-isucon13-contest1 --command-id RunShellScript --scripts 'hostname'"
echo ""
echo "SSH MCP Server FQDN:"
FQDN=$(azd env get-value SSH_MCP_SERVER_FQDN 2>/dev/null || echo "<check azd env get-values>")
echo "  $FQDN"

echo ""
echo "=== Post-provision complete ==="
