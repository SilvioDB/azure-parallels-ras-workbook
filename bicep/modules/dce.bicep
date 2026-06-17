// Data Collection Endpoint: provides the logsIngestion endpoint for the Logs Ingestion API.
// Must be in the same region as the workspace and the DCR.

@description('Nome del DCE.')
param dceName string

@description('Region (deve coincidere con workspace e DCR).')
param location string

resource dce 'Microsoft.Insights/dataCollectionEndpoints@2023-03-11' = {
  name: dceName
  location: location
  properties: {
    networkAcls: {
      publicNetworkAccess: 'Enabled'
    }
  }
}

output id string = dce.id
output logsIngestionEndpoint string = dce.properties.logsIngestion.endpoint
