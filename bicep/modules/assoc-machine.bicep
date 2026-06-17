// Internal module: creates the DCR-AMA association on ONE machine (Arc or Azure VM).
// Must be invoked with scope = resourceGroup of the machine (see associations.bicep).

@description('Nome della macchina (Arc machine o Azure VM).')
param machineName string

@description('Tipo macchina: arc (Microsoft.HybridCompute) oppure vm (Microsoft.Compute).')
@allowed([ 'arc', 'vm' ])
param machineKind string

@description('Resource ID della DCR-AMA da associare.')
param dcrId string

resource arcMachine 'Microsoft.HybridCompute/machines@2024-07-10' existing = if (machineKind == 'arc') {
  name: machineName
}

resource azureVm 'Microsoft.Compute/virtualMachines@2024-03-01' existing = if (machineKind == 'vm') {
  name: machineName
}

resource assocArc 'Microsoft.Insights/dataCollectionRuleAssociations@2023-03-11' = if (machineKind == 'arc') {
  name: 'ras-ama-dcr'
  scope: arcMachine
  properties: {
    dataCollectionRuleId: dcrId
    description: 'Associazione DCR-AMA RAS (Arc)'
  }
}

resource assocVm 'Microsoft.Insights/dataCollectionRuleAssociations@2023-03-11' = if (machineKind == 'vm') {
  name: 'ras-ama-dcr'
  scope: azureVm
  properties: {
    dataCollectionRuleId: dcrId
    description: 'Associazione DCR-AMA RAS (Azure VM)'
  }
}
