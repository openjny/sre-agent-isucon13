@description('Location for resources')
param location string

@description('Key Vault name to store the SSH private key')
param keyVaultName string

@description('Secret name for the SSH private key in Key Vault')
param sshKeySecretName string = 'ssh-private-key'

@description('Secret name for the TLS certificate in Key Vault')
param tlsCertSecretName string = 'tls-cert'

@description('Secret name for the TLS private key in Key Vault')
param tlsKeySecretName string = 'tls-key'

// ============================================================
// Managed Identity for deploymentScript (needs KV write access)
// ============================================================

resource scriptIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-ssh-keygen-script'
  location: location
}

// Key Vault Secrets Officer — allows set/get secrets
var kvSecretsOfficerRoleId = 'b86a8fe4-44ce-4948-aee5-eccb2c155cd7'

resource kvRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(keyVault.id, scriptIdentity.id, kvSecretsOfficerRoleId)
  scope: keyVault
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', kvSecretsOfficerRoleId)
    principalId: scriptIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' existing = {
  name: keyVaultName
}

// ============================================================
// Deployment Script: generate SSH key pair, store in Key Vault
// ============================================================

resource sshKeyGen 'Microsoft.Resources/deploymentScripts@2023-08-01' = {
  name: 'ssh-keygen-script'
  location: location
  kind: 'AzureCLI'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${scriptIdentity.id}': {}
    }
  }
  properties: {
    azCliVersion: '2.63.0'
    retentionInterval: 'P1D'
    forceUpdateTag: 'stable-v1'
    timeout: 'PT10M'
    cleanupPreference: 'OnSuccess'
    environmentVariables: [
      { name: 'KEY_VAULT_NAME', value: keyVaultName }
      { name: 'SECRET_NAME', value: sshKeySecretName }
      { name: 'TLS_CERT_SECRET', value: tlsCertSecretName }
      { name: 'TLS_KEY_SECRET', value: tlsKeySecretName }
    ]
    scriptContent: '''
      #!/bin/bash
      set -euo pipefail

      # ── SSH Key ──────────────────────────────────────────────
      # Check if key already exists in Key Vault
      EXISTING=$(az keyvault secret show --vault-name "$KEY_VAULT_NAME" --name "$SECRET_NAME" --query "value" -o tsv 2>/dev/null || echo "")
      if [[ -n "$EXISTING" ]]; then
        echo "SSH key already exists in Key Vault, extracting public key..."
        echo "$EXISTING" > /tmp/id_ed25519
        chmod 600 /tmp/id_ed25519
        ssh-keygen -y -f /tmp/id_ed25519 > /tmp/id_ed25519.pub
        rm /tmp/id_ed25519
      else
        echo "Generating new SSH key pair..."
        ssh-keygen -t ed25519 -f /tmp/id_ed25519 -N "" -q

        echo "Storing private key in Key Vault..."
        az keyvault secret set \
          --vault-name "$KEY_VAULT_NAME" \
          --name "$SECRET_NAME" \
          --file /tmp/id_ed25519 \
          --output none
      fi

      PUBLIC_KEY=$(cat /tmp/id_ed25519.pub)
      rm -f /tmp/id_ed25519 /tmp/id_ed25519.pub

      # ── TLS Certificate ─────────────────────────────────────
      EXISTING_CERT=$(az keyvault secret show --vault-name "$KEY_VAULT_NAME" --name "$TLS_CERT_SECRET" --query "value" -o tsv 2>/dev/null || echo "")
      if [[ -n "$EXISTING_CERT" ]]; then
        echo "TLS certificate already exists in Key Vault, skipping generation..."
      else
        echo "Generating self-signed TLS certificate for *.u.isucon.dev..."
        openssl req -x509 -newkey rsa:2048 \
          -keyout /tmp/tls.key -out /tmp/tls.crt \
          -days 3650 -nodes \
          -subj "/CN=*.u.isucon.dev" \
          -addext "subjectAltName=DNS:*.u.isucon.dev,DNS:u.isucon.dev"

        echo "Storing TLS certificate in Key Vault..."
        az keyvault secret set \
          --vault-name "$KEY_VAULT_NAME" \
          --name "$TLS_CERT_SECRET" \
          --file /tmp/tls.crt \
          --output none

        echo "Storing TLS private key in Key Vault..."
        az keyvault secret set \
          --vault-name "$KEY_VAULT_NAME" \
          --name "$TLS_KEY_SECRET" \
          --file /tmp/tls.key \
          --output none

        rm -f /tmp/tls.crt /tmp/tls.key
      fi

      echo "{\"publicKey\": \"$PUBLIC_KEY\"}" > $AZ_SCRIPTS_OUTPUT_PATH
    '''
  }
  dependsOn: [kvRole]
}

// ============================================================
// Outputs
// ============================================================

output sshPublicKey string = sshKeyGen.properties.outputs.publicKey
