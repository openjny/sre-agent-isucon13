@description('Location for all system resources')
param location string

@description('Enable Azure Monitor')
param enableMonitoring bool

@description('VM size for contest servers')
param vmSizeContest string

@description('VM size for benchmark server')
param vmSizeBench string

// ============================================================
// Variables — Static Private IPs
// ============================================================

var contestVmIps = ['10.0.1.4', '10.0.1.5', '10.0.1.6']
var benchVmIp = '10.0.1.7'
var uniqueSuffix = uniqueString(resourceGroup().id)
var shortSuffix = substring(uniqueSuffix, 0, 8)

// ============================================================
// Network
// ============================================================

module network 'modules/network.bicep' = {
  name: 'network'
  params: {
    location: location
  }
}

// ============================================================
// Key Vault (for SSH private key used by ISUCON MCP Server)
// ============================================================

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: 'kv-isucon13-${shortSuffix}'
  location: location
  tags: { project: 'isucon13' }
  properties: {
    sku: { family: 'A', name: 'standard' }
    tenantId: tenant().tenantId
    enableRbacAuthorization: true
  }
}

// Grant deployer Key Vault Secrets Officer so post-provision can store SSH keys
var kvSecretsOfficerRoleId = 'b86a8fe4-44ce-4948-aee5-eccb2c155cd7'

resource kvDeployerRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(keyVault.id, deployer().objectId, kvSecretsOfficerRoleId)
  scope: keyVault
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', kvSecretsOfficerRoleId)
    principalId: deployer().objectId
  }
}

// ============================================================
// ACR (for ISUCON MCP Server container image)
// ============================================================

resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' = {
  name: 'acrisucon13${shortSuffix}'
  location: location
  sku: { name: 'Basic' }
  tags: { project: 'isucon13' }
  properties: {
    adminUserEnabled: false
  }
}

// ============================================================
// SSH Key Generation (auto-generate + store in Key Vault)
// ============================================================

module sshKeyGen 'modules/ssh-keygen.bicep' = {
  name: 'ssh-keygen'
  params: {
    location: location
    keyVaultName: keyVault.name
  }
}

// ============================================================
// Contest VMs (x3)
// ============================================================

module contestVms 'modules/vm.bicep' = [
  for i in range(1, 3): {
    name: 'vm-contest${i}'
    params: {
      location: location
      subnetId: network.outputs.snetVmsId
      sshPublicKey: sshKeyGen.outputs.sshPublicKey
      vmSizeContest: vmSizeContest
      vmSizeBench: vmSizeBench
      contestVmIps: contestVmIps
      benchVmIp: benchVmIp
      role: 'contest'
      vmIndex: i
      privateIpAddress: contestVmIps[i - 1]
      keyVaultName: keyVault.name
    }
  }
]

// ============================================================
// Benchmark VM
// ============================================================

module benchVm 'modules/vm.bicep' = {
  name: 'vm-bench'
  params: {
    location: location
    subnetId: network.outputs.snetVmsId
    sshPublicKey: sshKeyGen.outputs.sshPublicKey
    vmSizeContest: vmSizeContest
    vmSizeBench: vmSizeBench
    contestVmIps: contestVmIps
    benchVmIp: benchVmIp
    role: 'bench'
    vmIndex: 1
    privateIpAddress: benchVmIp
    keyVaultName: keyVault.name
  }
}

// ============================================================
// ACA + ISUCON MCP Server
// ============================================================

var hostMap = {
  vm1: contestVmIps[0]
  vm2: contestVmIps[1]
  vm3: contestVmIps[2]
  bench: benchVmIp
}

// Generate a random API key for MCP server authentication
var mcpApiKey = uniqueString(resourceGroup().id, 'mcp-api-key', keyVault.id)

module aca 'modules/aca.bicep' = {
  name: 'aca'
  params: {
    location: location
    subnetId: network.outputs.snetAcaId
    acrLoginServer: acr.properties.loginServer
    acrName: acr.name
    keyVaultName: keyVault.name
    hostMapJson: string(hostMap)
    mcpApiKey: mcpApiKey
  }
}

// ============================================================
// Monitoring (optional)
// ============================================================

// ── Key Vault access for VMs (to retrieve TLS cert during provisioning) ─────
var kvSecretsUserRoleId = '4633458b-17de-408a-b874-0445c86b69e6' // Key Vault Secrets User

resource kvVmRoleContest 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for i in range(0, 3): {
    name: guid(keyVault.id, contestVms[i].outputs.vmPrincipalId, kvSecretsUserRoleId)
    scope: keyVault
    properties: {
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', kvSecretsUserRoleId)
      principalId: contestVms[i].outputs.vmPrincipalId
      principalType: 'ServicePrincipal'
    }
  }
]

resource kvVmRoleBench 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(keyVault.id, benchVm.outputs.vmPrincipalId, kvSecretsUserRoleId)
  scope: keyVault
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', kvSecretsUserRoleId)
    principalId: benchVm.outputs.vmPrincipalId
    principalType: 'ServicePrincipal'
  }
}

var allVmNames = [
  contestVms[0].outputs.vmName
  contestVms[1].outputs.vmName
  contestVms[2].outputs.vmName
  benchVm.outputs.vmName
]

var allVmIds = [
  contestVms[0].outputs.vmId
  contestVms[1].outputs.vmId
  contestVms[2].outputs.vmId
  benchVm.outputs.vmId
]

module monitoring 'modules/monitoring.bicep' = if (enableMonitoring) {
  name: 'monitoring'
  params: {
    location: location
    vmIds: allVmIds
    vmNames: allVmNames
  }
}

// ============================================================
// Outputs
// ============================================================

output vmContest1PrivateIp string = contestVmIps[0]
output vmContest2PrivateIp string = contestVmIps[1]
output vmContest3PrivateIp string = contestVmIps[2]
output vmBenchPrivateIp string = benchVmIp
output mcpServerFqdn string = aca.outputs.mcpServerFqdn
output acrLoginServer string = acr.properties.loginServer
output acrName string = acr.name
output acaEnvName string = aca.outputs.acaEnvName
output acaEnvId string = aca.outputs.acaEnvId
output keyVaultName string = keyVault.name
output mcpApiKey string = mcpApiKey
