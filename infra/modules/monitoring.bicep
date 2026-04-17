@description('Location for resources')
param location string

@description('VM resource IDs to attach AMA')
param vmIds array

@description('VM names for DCR association')
param vmNames array

// ============================================================
// Existing VM references (for scoping DCR associations)
// ============================================================

resource existingVms 'Microsoft.Compute/virtualMachines@2024-03-01' existing = [
  for i in range(0, length(vmNames)): {
    name: vmNames[i]
  }
]

// ============================================================
// Log Analytics Workspace
// ============================================================

resource law 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: 'law-isucon13'
  location: location
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
  }
}

// ============================================================
// Application Insights
// ============================================================

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: 'appi-isucon13'
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: law.id
  }
}

// ============================================================
// Data Collection Rule
// ============================================================

resource dcr 'Microsoft.Insights/dataCollectionRules@2023-03-11' = {
  name: 'dcr-isucon13'
  location: location
  properties: {
    dataSources: {
      syslog: [
        {
          name: 'syslog'
          streams: ['Microsoft-Syslog']
          facilityNames: ['daemon', 'auth', 'syslog']
          logLevels: ['Info', 'Notice', 'Warning', 'Error', 'Critical', 'Alert', 'Emergency']
        }
      ]
      performanceCounters: [
        {
          name: 'perfCounters'
          streams: ['Microsoft-Perf']
          samplingFrequencyInSeconds: 30
          counterSpecifiers: [
            '\\Processor(*)\\% Processor Time'
            '\\Memory\\% Used Memory'
            '\\LogicalDisk(*)\\% Used Space'
            '\\Network(*)\\Total Bytes Transmitted'
            '\\Network(*)\\Total Bytes Received'
          ]
        }
      ]
    }
    destinations: {
      logAnalytics: [
        {
          workspaceResourceId: law.id
          name: 'lawDest'
        }
      ]
    }
    dataFlows: [
      {
        streams: ['Microsoft-Syslog', 'Microsoft-Perf']
        destinations: ['lawDest']
      }
    ]
  }
}

// ============================================================
// Azure Monitor Agent Extension + DCR Association (per VM)
// ============================================================

@batchSize(1)
resource amaExtension 'Microsoft.Compute/virtualMachines/extensions@2024-03-01' = [
  for i in range(0, length(vmNames)): {
    name: '${vmNames[i]}/AzureMonitorLinuxAgent'
    location: location
    properties: {
      publisher: 'Microsoft.Azure.Monitor'
      type: 'AzureMonitorLinuxAgent'
      typeHandlerVersion: '1.0'
      autoUpgradeMinorVersion: true
      enableAutomaticUpgrade: true
    }
  }
]

resource dcrAssociation 'Microsoft.Insights/dataCollectionRuleAssociations@2023-03-11' = [
  for i in range(0, length(vmIds)): {
    name: 'dcra-${vmNames[i]}'
    scope: existingVms[i]
    properties: {
      dataCollectionRuleId: dcr.id
    }
    dependsOn: [amaExtension[i]]
  }
]

// ============================================================
// Outputs
// ============================================================

output lawId string = law.id
output lawName string = law.name
output appInsightsId string = appInsights.id
output appInsightsAppId string = appInsights.properties.AppId
output appInsightsConnectionString string = appInsights.properties.ConnectionString
