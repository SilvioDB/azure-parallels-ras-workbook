// ============================================================================
//  Azure Workbook for Parallels RAS - deployment package
//  Target scope: resource group (everything in one RG + region)
//  Dedicated Log Analytics workspace created here, not pre-existing.
// ============================================================================

targetScope = 'resourceGroup'

// --------------------------- General parameters ----------------------------

@description('Region for all resources. Must match the region of the Azure Arc servers.')
param location string = resourceGroup().location

// --------------------------- Naming convention -----------------------------
// Pattern (Microsoft CAF): <type>-<workload>-[<purpose>-]<env>-<regionCode>

@description('Workload/application label (name token).')
param workload string = 'ras'

@allowed([ 'prod', 'test', 'dev' ])
@description('Environment (name token).')
param environment string = 'prod'

@description('Short region code for the name (e.g. weu, neu, eus).')
param regionCode string = 'weu'

// --------------------------- Workspace (created here) ----------------------

@description('Name of the dedicated Log Analytics workspace.')
param workspaceName string = 'service-loganalytics-parallels'

@description('Retention (days) for tables in the workspace.')
param retentionInDays int = 30

// --------------------------- Perf counters ---------------------------------

@description('Performance counter sampling frequency (seconds).')
param samplingFrequencyInSeconds int = 60

// --------------------------- RAS machines ----------------------------------

@description('''
RAS machines to associate with the DCR-AMA. Each object:
{ name, kind: 'arc'|'vm', subscriptionId, resourceGroup }
''')
param machines array = []

@description('principalId (object id) of the collector host Managed Identities.')
param collectorPrincipalIds array = []

// --------------------------- Workbook --------------------------------------

@description('GUID for the Workbook resource name (deterministic by default).')
param workbookGuid string = guid(resourceGroup().id, 'ras-overview-workbook')

// --------------------------- Key Vault -------------------------------------

@description('Key Vault name for RAS credentials (max 24 chars).')
param keyVaultName string = 'kv-${workload}-${environment}-${regionCode}'

// ============================================================================
//  Derived values
// ============================================================================

var nameSuffix    = '${workload}-${environment}-${regionCode}'
var dceName       = 'dce-${nameSuffix}'
var dcrIngestName = 'dcr-${nameSuffix}-ingest'
var dcrAmaName    = 'dcr-${nameSuffix}-ama'

// ============================================================================
//  Modules
// ============================================================================

// 1) Dedicated Log Analytics workspace
module workspace 'modules/workspace.bicep' = {
  name: 'ras-workspace'
  params: {
    workspaceName: workspaceName
    location: location
    retentionInDays: retentionInDays
  }
}

// 2) Custom tables — same RG as the workspace (same RG as everything else)
module tables 'modules/tables.bicep' = {
  name: 'ras-tables'
  params: {
    workspaceName: workspaceName
    retentionInDays: retentionInDays
  }
  dependsOn: [ workspace ]
}

// 3) Data Collection Endpoint
module dce 'modules/dce.bicep' = {
  name: 'ras-dce'
  params: {
    dceName: dceName
    location: location
  }
}

// 4) DCR Ingestion (Logs Ingestion API)
module dcrIngest 'modules/dcr-ingest.bicep' = {
  name: 'ras-dcr-ingest'
  params: {
    dcrName: dcrIngestName
    location: location
    workspaceResourceId: workspace.outputs.workspaceId
    dceId: dce.outputs.id
  }
  dependsOn: [ tables ]
}

// 5) DCR AMA (perf + event)
module dcrAma 'modules/dcr-ama.bicep' = {
  name: 'ras-dcr-ama'
  params: {
    dcrName: dcrAmaName
    location: location
    workspaceResourceId: workspace.outputs.workspaceId
    samplingFrequencyInSeconds: samplingFrequencyInSeconds
  }
}

// 6) Associazioni DCR-AMA alle macchine (Arc + VM)
module associations 'modules/associations.bicep' = {
  name: 'ras-associations'
  params: {
    dcrId: dcrAma.outputs.id
    machines: machines
  }
}

// 7) RBAC: Monitoring Metrics Publisher on the DCR-Ingest for collector MIs
module rbac 'modules/rbac.bicep' = if (!empty(collectorPrincipalIds)) {
  name: 'ras-rbac'
  params: {
    dcrIngestName: dcrIngestName
    collectorPrincipalIds: collectorPrincipalIds
  }
  dependsOn: [ dcrIngest ]
}

// 8) Key Vault for RAS credentials
module kv 'modules/keyvault.bicep' = {
  name: 'ras-keyvault'
  params: {
    keyVaultName: keyVaultName
    location: location
    collectorPrincipalIds: collectorPrincipalIds
  }
}

// 9) Workbook
module workbook 'modules/workbook.bicep' = {
  name: 'ras-workbook'
  params: {
    location: location
    workspaceResourceId: workspace.outputs.workspaceId
    workbookGuid: workbookGuid
  }
}

// ============================================================================
//  Outputs (pass these to Install-RasCollectorTask.ps1)
// ============================================================================

output dceLogsIngestionEndpoint string = dce.outputs.logsIngestionEndpoint
output dcrIngestImmutableId string = dcrIngest.outputs.immutableId
output dcrAmaId string = dcrAma.outputs.id
output keyVaultName string = kv.outputs.keyVaultName
output keyVaultUri string = kv.outputs.keyVaultUri
output workspaceId string = workspace.outputs.workspaceId
output workbookId string = workbook.outputs.workbookId
output streams object = {
  server:  tables.outputs.serverStream
  agent:   tables.outputs.agentStream
  session: tables.outputs.sessionStream
  audit:   tables.outputs.auditStream
}
