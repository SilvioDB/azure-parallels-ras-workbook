// Custom tables (DCR-based) in the existing Log Analytics workspace.
// Each table receives RAS data via the Logs Ingestion API.

@description('Name of the existing Log Analytics workspace.')
param workspaceName string

@description('Retention in days for the custom tables.')
param retentionInDays int = 30

resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = {
  name: workspaceName
}

// --- RASServer_CL : farm server inventory and roles ---
resource tblServer 'Microsoft.OperationalInsights/workspaces/tables@2022-10-01' = {
  parent: workspace
  name: 'RASServer_CL'
  properties: {
    totalRetentionInDays: retentionInDays
    plan: 'Analytics'
    schema: {
      name: 'RASServer_CL'
      columns: [
        { name: 'TimeGenerated', type: 'datetime' }
        { name: 'Computer', type: 'string' }
        { name: 'FarmName', type: 'string' }
        { name: 'SiteName', type: 'string' }
        { name: 'Role', type: 'string' }          // RDSH | Gateway | Broker | Provider
        { name: 'ServerStatus', type: 'string' }  // OK | NotVerified | Error ...
        { name: 'AgentVersion', type: 'string' }
        { name: 'OSVersion', type: 'string' }
        { name: 'IPAddress', type: 'string' }
        { name: 'Enabled', type: 'boolean' }
      ]
    }
  }
}

// --- RASAgent_CL : versioni e stato degli agent ---
resource tblAgent 'Microsoft.OperationalInsights/workspaces/tables@2022-10-01' = {
  parent: workspace
  name: 'RASAgent_CL'
  properties: {
    totalRetentionInDays: retentionInDays
    plan: 'Analytics'
    schema: {
      name: 'RASAgent_CL'
      columns: [
        { name: 'TimeGenerated', type: 'datetime' }
        { name: 'Computer', type: 'string' }
        { name: 'SiteName', type: 'string' }
        { name: 'AgentType', type: 'string' }     // e.g. RDS, Gateway, Broker
        { name: 'AgentState', type: 'string' }    // Verified | NotVerified | NeedsUpdate ...
        { name: 'AgentVersion', type: 'string' }
        { name: 'OSVersion', type: 'string' }
      ]
    }
  }
}

// --- RASSession_CL : sessioni attive ---
resource tblSession 'Microsoft.OperationalInsights/workspaces/tables@2022-10-01' = {
  parent: workspace
  name: 'RASSession_CL'
  properties: {
    totalRetentionInDays: retentionInDays
    plan: 'Analytics'
    schema: {
      name: 'RASSession_CL'
      columns: [
        { name: 'TimeGenerated', type: 'datetime' }
        { name: 'Computer', type: 'string' }       // host serving the session
        { name: 'SiteName', type: 'string' }
        { name: 'SessionId', type: 'int' }
        { name: 'UserName', type: 'string' }
        { name: 'ClientName', type: 'string' }
        { name: 'ClientIP', type: 'string' }
        { name: 'SessionState', type: 'string' }   // Active | Disconnected | Idle ...
        { name: 'SessionType', type: 'string' }    // RDS | VDI
        { name: 'LogonTime', type: 'datetime' }
        { name: 'IdleTimeSec', type: 'int' }
        { name: 'PublishedResource', type: 'string' }
      ]
    }
  }
}

// --- RASAudit_CL : admin/operator activity ---
resource tblAudit 'Microsoft.OperationalInsights/workspaces/tables@2022-10-01' = {
  parent: workspace
  name: 'RASAudit_CL'
  properties: {
    totalRetentionInDays: retentionInDays
    plan: 'Analytics'
    schema: {
      name: 'RASAudit_CL'
      columns: [
        { name: 'TimeGenerated', type: 'datetime' }
        { name: 'SiteName', type: 'string' }
        { name: 'AdminUser', type: 'string' }
        { name: 'Action', type: 'string' }
        { name: 'ObjectType', type: 'string' }
        { name: 'ObjectName', type: 'string' }
        { name: 'Result', type: 'string' }
        { name: 'ClientIP', type: 'string' }
        { name: 'Source', type: 'string' }        // AdminSession | NotificationEvent
      ]
    }
  }
}

output serverStream string = 'Custom-RASServer_CL'
output agentStream string = 'Custom-RASAgent_CL'
output sessionStream string = 'Custom-RASSession_CL'
output auditStream string = 'Custom-RASAudit_CL'
