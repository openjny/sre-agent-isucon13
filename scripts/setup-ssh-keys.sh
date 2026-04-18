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
