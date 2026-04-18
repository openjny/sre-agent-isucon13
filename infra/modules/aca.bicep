@description('Location for resources')
param location string

@description('Subnet ID for ACA environment')
param subnetId string

@description('ACR login server (e.g., acrisucon13xxx.azurecr.io)')
param acrLoginServer string

@description('ACR name')
param acrName string

@description('Key Vault name containing SSH private key')
param keyVaultName string

@description('SSH private key secret name in Key Vault')
param sshKeySecretName string = 'ssh-private-key'

@description('Host map JSON: {"vm1":"10.0.1.4","vm2":"10.0.1.5","vm3":"10.0.1.6","bench":"10.0.1.7"}')
param hostMapJson string

@description('API key for MCP server authentication')
@secure()
param mcpApiKey string

// ============================================================
// Managed Identity for ACA
// ============================================================

resource acaIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-aca-ssh-mcp'
  location: location
}

// ============================================================
// ACR pull role for ACA identity
// ============================================================

var acrPullRoleId = '7f951dda-4ed3-4680-a7ca-43fe172d538d' // AcrPull

resource acrPullRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(acr.id, acaIdentity.id, acrPullRoleId)
  scope: acr
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', acrPullRoleId)
    principalId: acaIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// ============================================================
// Key Vault access for ACA identity
// ============================================================

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' existing = {
  name: keyVaultName
}

var kvSecretsUserRoleId = '4633458b-17de-408a-b874-0445c86b69e6' // Key Vault Secrets User

resource kvSecretsRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(keyVault.id, acaIdentity.id, kvSecretsUserRoleId)
  scope: keyVault
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', kvSecretsUserRoleId)
    principalId: acaIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// ============================================================
// ACR (existing reference)
// ============================================================

resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' existing = {
  name: acrName
}

// ============================================================
// Container Apps Environment
// ============================================================

resource acaEnv 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: 'cae-isucon13'
  location: location
  properties: {
    vnetConfiguration: {
      infrastructureSubnetId: subnetId
      internal: false
    }
  }
}

// ============================================================
// SSH MCP Server Container App
// ============================================================

resource sshMcpApp 'Microsoft.App/containerApps@2024-03-01' = {
  name: 'ca-ssh-mcp-server'
  location: location
  tags: {
    'azd-service-name': 'ssh-mcp-server'
  }
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${acaIdentity.id}': {}
    }
  }
  properties: {
    managedEnvironmentId: acaEnv.id
    configuration: {
      secrets: [
        {
          name: 'mcp-api-key'
          value: mcpApiKey
        }
      ]
      ingress: {
        external: true
        targetPort: 8080
        transport: 'auto'
      }
      registries: [
        {
          server: acrLoginServer
          identity: acaIdentity.id
        }
      ]
    }
    template: {
      containers: [
        {
          name: 'ssh-mcp-server'
          image: 'mcr.microsoft.com/azuredocs/containerapps-helloworld:latest'
          resources: {
            cpu: json('0.5')
            memory: '1Gi'
          }
          env: [
            { name: 'HOST_MAP', value: hostMapJson }
            { name: 'SSH_USER', value: 'isucon' }
            { name: 'AZURE_KEY_VAULT_URL', value: keyVault.properties.vaultUri }
            { name: 'SSH_KEY_SECRET_NAME', value: sshKeySecretName }
            { name: 'AZURE_CLIENT_ID', value: acaIdentity.properties.clientId }
            { name: 'API_KEY', secretRef: 'mcp-api-key' }
          ]
        }
      ]
      scale: {
        minReplicas: 1
        maxReplicas: 1
      }
    }
  }
}

// ============================================================
// Outputs
// ============================================================

output acaEnvId string = acaEnv.id
output acaEnvName string = acaEnv.name
output sshMcpServerFqdn string = sshMcpApp.properties.configuration.ingress.fqdn
output acaIdentityPrincipalId string = acaIdentity.properties.principalId
