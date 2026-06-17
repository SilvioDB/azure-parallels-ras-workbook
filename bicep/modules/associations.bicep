// Associates the DCR-AMA with all RAS machines (Arc + Azure VM), including cross-resource-group.
// Each element of 'machines' describes one machine; the inner module runs in the scope
// of its resource group.

@description('Resource ID of the DCR-AMA.')
param dcrId string

@description('''
List of machines to associate. Each object:
{
  name: 'RAS-CB-01'            // Arc/VM resource name
  kind: 'arc' | 'vm'
  subscriptionId: '<guid>'    // subscription of the machine
  resourceGroup: 'rg-...'     // RG of the machine
}
''')
param machines array

module assoc 'assoc-machine.bicep' = [for (m, i) in machines: {
  name: 'ras-ama-assoc-${i}'
  scope: resourceGroup(m.subscriptionId, m.resourceGroup)
  params: {
    machineName: m.name
    machineKind: m.kind
    dcrId: dcrId
  }
}]
