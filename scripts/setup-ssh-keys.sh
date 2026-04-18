#!/bin/bash
set -euo pipefail

# Generate SSH key pair, store in Key Vault, and distribute to all VMs.
# Run after azd provision completes.

RG=$(azd env get-value SYSTEM_RESOURCE_GROUP 2>/dev/null || echo "rg-isucon13-system")
KV_NAME=$(az keyvault list -g "$RG" --query "[0].name" -o tsv)

if [ -z "$KV_NAME" ]; then
  echo "❌ No Key Vault found in $RG"
  exit 1
fi

echo "Key Vault: $KV_NAME"

# Check if key already exists
if az keyvault secret show --vault-name "$KV_NAME" --name ssh-private-key --query id -o tsv &>/dev/null; then
  echo "SSH key already exists in Key Vault. Skipping generation."
  echo "To regenerate, delete the secret first:"
  echo "  az keyvault secret delete --vault-name $KV_NAME --name ssh-private-key"
  exit 0
fi

SSH_DIR=$(mktemp -d)
ssh-keygen -t ed25519 -f "$SSH_DIR/id_ed25519" -N "" -q
echo "Generated key pair"

az keyvault secret set --vault-name "$KV_NAME" --name "ssh-private-key" --file "$SSH_DIR/id_ed25519" -o none
echo "Private key stored in Key Vault"

PUBLIC_KEY=$(cat "$SSH_DIR/id_ed25519.pub")
echo "Public key: $PUBLIC_KEY"

for VM in vm-isucon13-contest1 vm-isucon13-contest2 vm-isucon13-contest3 vm-isucon13-bench; do
  echo "Adding key to $VM..."
  az vm run-command invoke -g "$RG" -n "$VM" --command-id RunShellScript \
    --scripts "mkdir -p /home/isucon/.ssh && echo '${PUBLIC_KEY}' >> /home/isucon/.ssh/authorized_keys && chown -R isucon:isucon /home/isucon/.ssh && chmod 700 /home/isucon/.ssh && chmod 600 /home/isucon/.ssh/authorized_keys" \
    -o none
  echo "  Done: $VM"
done

rm -rf "$SSH_DIR"
echo "=== SSH key setup complete ==="
#!/bin/bash
set -euo pipefail

KV_NAME="kv-isucon13-rkamflau"
RG="rg-isucon13-system"

SSH_DIR=$(mktemp -d)
ssh-keygen -t ed25519 -f "$SSH_DIR/id_ed25519" -N "" -q
echo "Generated key pair"

az keyvault secret set --vault-name "$KV_NAME" --name "ssh-private-key" --file "$SSH_DIR/id_ed25519" -o none
echo "Private key stored in Key Vault"

PUBLIC_KEY=$(cat "$SSH_DIR/id_ed25519.pub")
echo "Public key: $PUBLIC_KEY"

for VM in vm-isucon13-contest1 vm-isucon13-contest2 vm-isucon13-contest3 vm-isucon13-bench; do
  echo "Adding key to $VM..."
  az vm run-command invoke -g "$RG" -n "$VM" --command-id RunShellScript \
    --scripts "mkdir -p /home/isucon/.ssh && echo '${PUBLIC_KEY}' >> /home/isucon/.ssh/authorized_keys && chown -R isucon:isucon /home/isucon/.ssh && chmod 700 /home/isucon/.ssh && chmod 600 /home/isucon/.ssh/authorized_keys" \
    -o none
  echo "  Done: $VM"
done

rm -rf "$SSH_DIR"
echo "=== SSH key setup complete ==="
