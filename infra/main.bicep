targetScope = 'subscription'

// ============================================================
// Parameters
// ============================================================

@description('Primary location for system resources (VMs, VNet, ACA)')
param location string = 'southeastasia'

@description('Location for SRE Agent resource')
@allowed(['australiaeast', 'eastus2', 'swedencentral'])
param sreAgentLocation string = 'australiaeast'

@description('Enable Azure Monitor (Log Analytics, AMA, DCR)')
param enableMonitoring bool = false

@description('VM size for contest servers')
param vmSizeContest string = 'Standard_D2s_v5'

@description('VM size for benchmark server')
param vmSizeBench string = 'Standard_D4s_v5'

// ============================================================
// Resource Groups
// ============================================================

resource rgSystem 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: 'rg-isucon13-system'
  location: location
}

resource rgSreAgent 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: 'rg-isucon13-sreagent'
  location: sreAgentLocation
}

// ============================================================
// System Resources (VNet, VMs, ACA, etc.)
// ============================================================

module systemResources 'resources-system.bicep' = {
  name: 'system-resources'
  scope: rgSystem
  params: {
    location: location
    enableMonitoring: enableMonitoring
    vmSizeContest: vmSizeContest
    vmSizeBench: vmSizeBench
  }
}

// ============================================================
// SRE Agent Resources
// ============================================================

module sreAgentResources 'resources-sreagent.bicep' = {
  name: 'sreagent-resources'
  scope: rgSreAgent
  params: {
    location: sreAgentLocation
    systemResourceGroupId: rgSystem.id
  }
}

// ============================================================
// Cross-RG RBAC: SRE Agent identity -> system RG Reader
// ============================================================

module crossRgRbac 'modules/cross-rg-rbac.bicep' = {
  name: 'cross-rg-rbac'
  scope: rgSystem
  params: {
    principalId: sreAgentResources.outputs.agentIdentityPrincipalId
  }
}

// ============================================================
// Outputs
// ============================================================

output AZURE_LOCATION string = location
output SRE_AGENT_LOCATION string = sreAgentLocation
output SYSTEM_RESOURCE_GROUP string = rgSystem.name
output SREAGENT_RESOURCE_GROUP string = rgSreAgent.name
output VM_CONTEST1_PRIVATE_IP string = systemResources.outputs.vmContest1PrivateIp
output VM_CONTEST2_PRIVATE_IP string = systemResources.outputs.vmContest2PrivateIp
output VM_CONTEST3_PRIVATE_IP string = systemResources.outputs.vmContest3PrivateIp
output VM_BENCH_PRIVATE_IP string = systemResources.outputs.vmBenchPrivateIp
output SSH_MCP_SERVER_FQDN string = systemResources.outputs.sshMcpServerFqdn
output SRE_AGENT_NAME string = sreAgentResources.outputs.agentName
output SRE_AGENT_PORTAL_URL string = 'https://sre.azure.com'
