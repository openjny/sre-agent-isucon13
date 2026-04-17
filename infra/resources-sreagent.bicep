@description('Location for SRE Agent resources')
param location string

@description('System Resource Group ID')
param systemResourceGroupId string

// ============================================================
// SRE Agent
// ============================================================

module sreAgent 'modules/sre-agent.bicep' = {
  name: 'sre-agent'
  params: {
    location: location
    systemResourceGroupId: systemResourceGroupId
  }
}

// ============================================================
// Outputs
// ============================================================

output agentName string = sreAgent.outputs.agentName
output agentEndpoint string = sreAgent.outputs.agentEndpoint
output agentPortalUrl string = sreAgent.outputs.agentPortalUrl
output agentIdentityPrincipalId string = sreAgent.outputs.agentIdentityPrincipalId
