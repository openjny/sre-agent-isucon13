@description('Location for resources')
param location string

// ============================================================
// NSG for VM subnet
// ============================================================

resource nsgVms 'Microsoft.Network/networkSecurityGroups@2024-01-01' = {
  name: 'nsg-isucon13-vms'
  location: location
  properties: {
    securityRules: [
      {
        name: 'AllowSSHInbound'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: 'VirtualNetwork'
          destinationPortRange: '22'
        }
      }
      {
        name: 'AllowHTTPSInbound'
        properties: {
          priority: 110
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: 'VirtualNetwork'
          destinationPortRange: '443'
        }
      }
      {
        name: 'AllowDNSInbound'
        properties: {
          priority: 120
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Udp'
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: 'VirtualNetwork'
          destinationPortRange: '53'
        }
      }
      {
        name: 'AllowMySQLInbound'
        properties: {
          priority: 130
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: 'VirtualNetwork'
          destinationPortRange: '3306'
        }
      }
    ]
  }
}

// ============================================================
// NAT Gateway (for outbound internet from VMs - package installs)
// ============================================================

resource natGwPublicIp 'Microsoft.Network/publicIPAddresses@2024-01-01' = {
  name: 'pip-natgw-isucon13'
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource natGw 'Microsoft.Network/natGateways@2024-01-01' = {
  name: 'natgw-isucon13'
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIpAddresses: [
      { id: natGwPublicIp.id }
    ]
    idleTimeoutInMinutes: 10
  }
}

// ============================================================
// VNet
// ============================================================

resource vnet 'Microsoft.Network/virtualNetworks@2024-01-01' = {
  name: 'vnet-isucon13'
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: ['10.0.0.0/16']
    }
    subnets: [
      {
        name: 'snet-vms'
        properties: {
          addressPrefix: '10.0.1.0/24'
          networkSecurityGroup: { id: nsgVms.id }
          natGateway: { id: natGw.id }
        }
      }
      {
        name: 'snet-aca'
        properties: {
          addressPrefix: '10.0.2.0/23'
          delegations: [
            {
              name: 'Microsoft.App.environments'
              properties: {
                serviceName: 'Microsoft.App/environments'
              }
            }
          ]
          natGateway: { id: natGw.id }
        }
      }
    ]
  }
}

// ============================================================
// Outputs
// ============================================================

output vnetId string = vnet.id
output vnetName string = vnet.name
output snetVmsId string = vnet.properties.subnets[0].id
output snetAcaId string = vnet.properties.subnets[1].id
