using './main.bicep'

param location = readEnvironmentVariable('AZURE_LOCATION', 'southeastasia')
param sreAgentLocation = readEnvironmentVariable('SRE_AGENT_LOCATION', 'australiaeast')
param enableMonitoring = bool(readEnvironmentVariable('ENABLE_MONITORING', 'false'))
param vmSizeContest = readEnvironmentVariable('VM_SIZE_CONTEST', 'Standard_D2s_v5')
param vmSizeBench = readEnvironmentVariable('VM_SIZE_BENCH', 'Standard_D4s_v5')
