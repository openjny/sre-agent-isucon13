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
