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
// Key Vault (for SSH private key used by SSH MCP Server)
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

// ============================================================
// ACR (for SSH MCP Server container image)
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
  }
}

// ============================================================
// ACA + SSH MCP Server
// ============================================================

var hostMap = {
  vm1: contestVmIps[0]
  vm2: contestVmIps[1]
  vm3: contestVmIps[2]
  bench: benchVmIp
}

module aca 'modules/aca.bicep' = {
  name: 'aca'
  params: {
    location: location
    subnetId: network.outputs.snetAcaId
    acrLoginServer: acr.properties.loginServer
    acrName: acr.name
    keyVaultName: keyVault.name
    hostMapJson: string(hostMap)
  }
}

// ============================================================
// Monitoring (optional)
// ============================================================

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
output sshMcpServerFqdn string = aca.outputs.sshMcpServerFqdn
output acrLoginServer string = acr.properties.loginServer
output acrName string = acr.name
output acaEnvName string = aca.outputs.acaEnvName
output acaEnvId string = aca.outputs.acaEnvId
output keyVaultName string = keyVault.name
