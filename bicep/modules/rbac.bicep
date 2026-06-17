// Assigns 'Monitoring Metrics Publisher' on the DCR-Ingest to the collector host Managed Identities
// so the script can publish data via the Logs Ingestion API.

@description('Nome della DCR-Ingest (stesso RG del deployment).')
param dcrIngestName string

@description('Lista dei principalId (object id) delle Managed Identity degli host collector.')
param collectorPrincipalIds array

// Monitoring Metrics Publisher
var roleId = '3913510d-42f4-4e42-8a64-420c390055eb'

resource dcr 'Microsoft.Insights/dataCollectionRules@2023-03-11' existing = {
  name: dcrIngestName
}

resource ra 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for pid in collectorPrincipalIds: {
  name: guid(dcr.id, pid, roleId)
  scope: dcr
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleId)
    principalId: pid
    principalType: 'ServicePrincipal'
  }
}]
