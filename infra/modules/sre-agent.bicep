@description('Location for SRE Agent resource')
param location string

@description('Resource Group ID of the system resources to manage')
param systemResourceGroupId string

// ============================================================
// Variables
// ============================================================

var uniqueSuffix = uniqueString(resourceGroup().id)
var agentName = 'sre-agent-isucon13-${uniqueSuffix}'
var identityName = 'id-sre-agent-${uniqueSuffix}'
var logAnalyticsName = 'law-sreagent-${uniqueSuffix}'
var appInsightsName = 'appi-sreagent-${uniqueSuffix}'

// ============================================================
// Log Analytics + App Insights (required by SRE Agent)
// ============================================================

resource law 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: logAnalyticsName
  location: location
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: 30
  }
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: appInsightsName
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: law.id
  }
}

// ============================================================
// Managed Identity for SRE Agent
// ============================================================

resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: identityName
  location: location
}

// ============================================================
// SRE Agent
// ============================================================

#disable-next-line BCP081
resource sreAgent 'Microsoft.App/agents@2025-05-01-preview' = {
  name: agentName
  location: location
  tags: {
    'hidden-link:/app-insights-resource-id': appInsights.id
  }
  identity: {
    type: 'SystemAssigned, UserAssigned'
    userAssignedIdentities: {
      '${identity.id}': {}
    }
  }
  properties: {
    knowledgeGraphConfiguration: {
      managedResources: [
        systemResourceGroupId
      ]
      identity: identity.id
    }
    actionConfiguration: {
      mode: 'autonomous'
      identity: identity.id
      accessLevel: 'Low'
    }
    mcpServers: []
    logConfiguration: {
      applicationInsightsConfiguration: {
        appId: appInsights.properties.AppId
        connectionString: appInsights.properties.ConnectionString
      }
    }
  }
}

// ============================================================
// SRE Agent Administrator role to deployer
// ============================================================

var sreAgentAdminRoleId = 'e79298df-d852-4c6d-84f9-5d13249d1e55'

resource sreAgentAdminRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(sreAgent.id, deployer().objectId, sreAgentAdminRoleId)
  scope: sreAgent
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', sreAgentAdminRoleId)
    principalId: deployer().objectId
    principalType: 'User'
  }
}

// ============================================================
// Outputs
// ============================================================

output agentName string = sreAgent.name
output agentId string = sreAgent.id
output agentEndpoint string = sreAgent.properties.agentEndpoint
output agentPortalUrl string = 'https://sre.azure.com'
output agentIdentityPrincipalId string = identity.properties.principalId
