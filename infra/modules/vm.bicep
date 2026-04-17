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

// ============================================================
// Variables
// ============================================================

var vmName = role == 'bench' ? 'vm-isucon13-bench' : 'vm-isucon13-contest${vmIndex}'
var vmSize = role == 'bench' ? vmSizeBench : vmSizeContest
var privateIpAddress = role == 'bench' ? benchVmIp : contestVmIps[vmIndex - 1]
var adminUsername = 'isucon'

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
      }
    }
    networkProfile: {
      networkInterfaces: [
        { id: nic.id }
      ]
    }
  }
}

// ============================================================
// Custom Script Extension — bootstrap ISUCON13 environment
// ============================================================

var bootstrapArgs = role == 'bench'
  ? '--role bench --contest-ips ${allContestIps} --bench-ip ${benchVmIp}'
  : '--role contest --contest-ips ${allContestIps} --bench-ip ${benchVmIp} --vm-index ${vmIndex}'

resource cse 'Microsoft.Compute/virtualMachines/extensions@2024-03-01' = {
  parent: vm
  name: 'CustomScript'
  location: location
  properties: {
    publisher: 'Microsoft.Azure.Extensions'
    type: 'CustomScript'
    typeHandlerVersion: '2.1'
    autoUpgradeMinorVersion: true
    protectedSettings: {
      script: loadFileAsBase64('../../provisioning/bootstrap.sh')
      commandToExecute: 'bash /var/lib/waagent/custom-script/download/0/bootstrap.sh ${bootstrapArgs}'
    }
  }
}

// ============================================================
// Outputs
// ============================================================

output vmId string = vm.id
output vmName string = vm.name
output privateIpAddress string = privateIpAddress
output vmPrincipalId string = vm.identity.principalId
