// DCR for the Logs Ingestion API (Pipeline B).
// Receives JSON payloads from the collector script and routes them into the custom tables.
// Script uses: <dceLogsIngestionEndpoint>/dataCollectionRules/<immutableId>/streams/<stream>?api-version=2023-01-01

@description('Nome della DCR di ingestion.')
param dcrName string

@description('Region (deve coincidere con workspace e DCE).')
param location string

@description('Resource ID del Log Analytics workspace.')
param workspaceResourceId string

@description('Resource ID del DCE.')
param dceId string

// streamDeclarations columns must match the JSON sent by the script.
// The 'source' transformation passes data unchanged (schema = table schema).

resource dcr 'Microsoft.Insights/dataCollectionRules@2023-03-11' = {
  name: dcrName
  location: location
  properties: {
    dataCollectionEndpointId: dceId
    streamDeclarations: {
      'Custom-RASServer_CL': {
        columns: [
          { name: 'TimeGenerated', type: 'datetime' }
          { name: 'Computer', type: 'string' }
          { name: 'FarmName', type: 'string' }
          { name: 'SiteName', type: 'string' }
          { name: 'Role', type: 'string' }
          { name: 'ServerStatus', type: 'string' }
          { name: 'AgentVersion', type: 'string' }
          { name: 'OSVersion', type: 'string' }
          { name: 'IPAddress', type: 'string' }
          { name: 'Enabled', type: 'boolean' }
        ]
      }
      'Custom-RASAgent_CL': {
        columns: [
          { name: 'TimeGenerated', type: 'datetime' }
          { name: 'Computer', type: 'string' }
          { name: 'SiteName', type: 'string' }
          { name: 'AgentType', type: 'string' }
          { name: 'AgentState', type: 'string' }
          { name: 'AgentVersion', type: 'string' }
          { name: 'OSVersion', type: 'string' }
        ]
      }
      'Custom-RASSession_CL': {
        columns: [
          { name: 'TimeGenerated', type: 'datetime' }
          { name: 'Computer', type: 'string' }
          { name: 'SiteName', type: 'string' }
          { name: 'SessionId', type: 'int' }
          { name: 'UserName', type: 'string' }
          { name: 'ClientName', type: 'string' }
          { name: 'ClientIP', type: 'string' }
          { name: 'SessionState', type: 'string' }
          { name: 'SessionType', type: 'string' }
          { name: 'LogonTime', type: 'datetime' }
          { name: 'IdleTimeSec', type: 'int' }
          { name: 'PublishedResource', type: 'string' }
        ]
      }
      'Custom-RASSessionHistory_CL': {
        columns: [
          { name: 'TimeGenerated', type: 'datetime' }
          { name: 'EventTime', type: 'datetime' }
          { name: 'EventType', type: 'string' }
          { name: 'SessionKey', type: 'string' }
          { name: 'Computer', type: 'string' }
          { name: 'SiteName', type: 'string' }
          { name: 'SessionId', type: 'int' }
          { name: 'UserName', type: 'string' }
          { name: 'ClientName', type: 'string' }
          { name: 'ClientIP', type: 'string' }
          { name: 'SessionState', type: 'string' }
          { name: 'PreviousSessionState', type: 'string' }
          { name: 'SessionType', type: 'string' }
          { name: 'LogonTime', type: 'datetime' }
          { name: 'FirstSeen', type: 'datetime' }
          { name: 'LastSeen', type: 'datetime' }
          { name: 'ObservedDurationSec', type: 'int' }
          { name: 'IdleTimeSec', type: 'int' }
          { name: 'PublishedResource', type: 'string' }
          { name: 'Source', type: 'string' }
        ]
      }
      'Custom-RASAudit_CL': {
        columns: [
          { name: 'TimeGenerated', type: 'datetime' }
          { name: 'SiteName', type: 'string' }
          { name: 'AdminUser', type: 'string' }
          { name: 'Action', type: 'string' }
          { name: 'ObjectType', type: 'string' }
          { name: 'ObjectName', type: 'string' }
          { name: 'Result', type: 'string' }
          { name: 'ClientIP', type: 'string' }
          { name: 'Source', type: 'string' }
        ]
      }
    }
    destinations: {
      logAnalytics: [
        {
          name: 'laDest'
          workspaceResourceId: workspaceResourceId
        }
      ]
    }
    dataFlows: [
      {
        streams: [ 'Custom-RASServer_CL' ]
        destinations: [ 'laDest' ]
        transformKql: 'source'
        outputStream: 'Custom-RASServer_CL'
      }
      {
        streams: [ 'Custom-RASAgent_CL' ]
        destinations: [ 'laDest' ]
        transformKql: 'source'
        outputStream: 'Custom-RASAgent_CL'
      }
      {
        streams: [ 'Custom-RASSession_CL' ]
        destinations: [ 'laDest' ]
        transformKql: 'source'
        outputStream: 'Custom-RASSession_CL'
      }
      {
        streams: [ 'Custom-RASSessionHistory_CL' ]
        destinations: [ 'laDest' ]
        transformKql: 'source'
        outputStream: 'Custom-RASSessionHistory_CL'
      }
      {
        streams: [ 'Custom-RASAudit_CL' ]
        destinations: [ 'laDest' ]
        transformKql: 'source'
        outputStream: 'Custom-RASAudit_CL'
      }
    ]
  }
}

output id string = dcr.id
output immutableId string = dcr.properties.immutableId
