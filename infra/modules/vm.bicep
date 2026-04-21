@description('Location for resources')
param location string

@description('Subnet ID for VM NICs')
param subnetId string

@description('SSH public key')
param sshPublicKey string

@description('VM size for contest servers')
param vmSizeContest string

@description('VM size for benchmark server')
param vmSizeBench string

@description('Private IPs for all contest VMs (for DNS zone init)')
param contestVmIps array

@description('Private IP for benchmark VM')
param benchVmIp string

@description('Role: contest or bench')
@allowed(['contest', 'bench'])
param role string

@description('VM index (1-based, used for naming)')
param vmIndex int

@description('Key Vault name for TLS certificate retrieval')
param keyVaultName string

// ============================================================
// Variables
// ============================================================

var vmName = role == 'bench' ? 'vm-isucon13-bench' : 'vm-isucon13-contest${vmIndex}'
var vmSize = role == 'bench' ? vmSizeBench : vmSizeContest
var adminUsername = 'isucon'

// Private IP: passed directly as a parameter to avoid ARM index evaluation issues
@description('Static private IP for this VM')
param privateIpAddress string

// All VM IPs for bootstrap script
var allContestIps = join(contestVmIps, ',')

// ============================================================
// NIC (static private IP)
// ============================================================

resource nic 'Microsoft.Network/networkInterfaces@2024-01-01' = {
  name: 'nic-${vmName}'
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: { id: subnetId }
          privateIPAllocationMethod: 'Static'
          privateIPAddress: privateIpAddress
        }
      }
    ]
  }
}

// ============================================================
// VM
// ============================================================

resource vm 'Microsoft.Compute/virtualMachines@2024-03-01' = {
  name: vmName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    osProfile: {
      computerName: vmName
      adminUsername: adminUsername
      linuxConfiguration: {
        disablePasswordAuthentication: true
        ssh: {
          publicKeys: [
            {
              path: '/home/${adminUsername}/.ssh/authorized_keys'
              keyData: sshPublicKey
            }
          ]
        }
      }
    }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: '0001-com-ubuntu-server-jammy'
        sku: '22_04-lts-gen2'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        diskSizeGB: 40
        managedDisk: {
          storageAccountType: 'Premium_LRS'
        }
        deleteOption: 'Delete'
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nic.id
          properties: {
            deleteOption: 'Delete'
          }
        }
      ]
    }
  }
}

// ============================================================
// Key Vault RBAC — grant VM identity Secrets User before CSE runs
// ============================================================

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' existing = {
  name: keyVaultName
}

var kvSecretsUserRoleId = '4633458b-17de-408a-b874-0445c86b69e6' // Key Vault Secrets User

resource kvVmRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(keyVault.id, vm.id, kvSecretsUserRoleId)
  scope: keyVault
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', kvSecretsUserRoleId)
    principalId: vm.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// ============================================================
// Custom Script Extension — bootstrap ISUCON13 environment
// ============================================================

var bootstrapArgs = role == 'bench'
  ? '--role bench --contest-ips ${allContestIps} --bench-ip ${benchVmIp} --key-vault ${keyVaultName}'
  : '--role contest --contest-ips ${allContestIps} --bench-ip ${benchVmIp} --vm-index ${vmIndex} --key-vault ${keyVaultName}'

// Force CSE re-run on each deployment by including deployment timestamp
@description('Deployment timestamp to force CSE re-execution')
param deployTimestamp string = utcNow()

// Inline the bootstrap invocation: download repo + run script with args
var scriptContent = '''#!/bin/bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq && apt-get install -y -qq git
ISUCON_REPO=/tmp/sre-agent-isucon13
# Always fresh clone
rm -rf "$ISUCON_REPO"
git clone --depth 1 https://github.com/openjny/sre-agent-isucon13.git "$ISUCON_REPO"
cd "$ISUCON_REPO/scripts"
chmod +x provision-vm.sh provision-vm-contest.sh provision-vm-benchmark.sh
bash provision-vm.sh '''

resource cse 'Microsoft.Compute/virtualMachines/extensions@2024-03-01' = {
  parent: vm
  name: 'CustomScript'
  location: location
  properties: {
    publisher: 'Microsoft.Azure.Extensions'
    type: 'CustomScript'
    typeHandlerVersion: '2.1'
    autoUpgradeMinorVersion: true
    forceUpdateTag: deployTimestamp
    protectedSettings: {
      script: base64('${scriptContent}${bootstrapArgs}')
    }
  }
  dependsOn: [kvVmRole]
}

// ============================================================
// Outputs
// ============================================================

output vmId string = vm.id
output vmName string = vm.name
output privateIpAddress string = privateIpAddress
output vmPrincipalId string = vm.identity.principalId
