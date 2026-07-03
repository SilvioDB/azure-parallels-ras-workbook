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

// --- RASSessionHistory_CL : eventi derivati dalle snapshot sessioni ---
resource tblSessionHistory 'Microsoft.OperationalInsights/workspaces/tables@2022-10-01' = {
  parent: workspace
  name: 'RASSessionHistory_CL'
  properties: {
    totalRetentionInDays: retentionInDays
    plan: 'Analytics'
    schema: {
      name: 'RASSessionHistory_CL'
      columns: [
        { name: 'TimeGenerated', type: 'datetime' }
        { name: 'EventTime', type: 'datetime' }
        { name: 'EventType', type: 'string' }             // Started | Observed | StateChanged | EndedInferred
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
  }
}

// --- RASApplicationUsage_CL : utilizzo applicazioni / published resource ---
resource tblApplicationUsage 'Microsoft.OperationalInsights/workspaces/tables@2022-10-01' = {
  parent: workspace
  name: 'RASApplicationUsage_CL'
  properties: {
    totalRetentionInDays: retentionInDays
    plan: 'Analytics'
    schema: {
      name: 'RASApplicationUsage_CL'
      columns: [
        { name: 'TimeGenerated', type: 'datetime' }
        { name: 'ApplicationName', type: 'string' }
        { name: 'PublishedResource', type: 'string' }
        { name: 'UserName', type: 'string' }
        { name: 'Computer', type: 'string' }
        { name: 'SessionId', type: 'int' }
        { name: 'SessionKey', type: 'string' }
        { name: 'PID', type: 'int' }
        { name: 'Started', type: 'datetime' }
        { name: 'Ended', type: 'datetime' }
        { name: 'DurationSec', type: 'int' }
        { name: 'Source', type: 'string' }
      ]
    }
  }
}

// --- RASConnectionEvent_CL : logon, logoff, disconnect, reconnect ---
resource tblConnectionEvent 'Microsoft.OperationalInsights/workspaces/tables@2022-10-01' = {
  parent: workspace
  name: 'RASConnectionEvent_CL'
  properties: {
    totalRetentionInDays: retentionInDays
    plan: 'Analytics'
    schema: {
      name: 'RASConnectionEvent_CL'
      columns: [
        { name: 'TimeGenerated', type: 'datetime' }
        { name: 'EventTime', type: 'datetime' }
        { name: 'EventType', type: 'string' }
        { name: 'UserName', type: 'string' }
        { name: 'Computer', type: 'string' }
        { name: 'SessionId', type: 'int' }
        { name: 'SessionKey', type: 'string' }
        { name: 'ClientName', type: 'string' }
        { name: 'ClientIP', type: 'string' }
        { name: 'PublishedResource', type: 'string' }
        { name: 'TransportProtocol', type: 'string' }
        { name: 'DisconnectReason', type: 'string' }
        { name: 'SourceEventId', type: 'int' }
        { name: 'Source', type: 'string' }
      ]
    }
  }
}

// --- RASDevice_CL : inventory dispositivi/client osservati ---
resource tblDevice 'Microsoft.OperationalInsights/workspaces/tables@2022-10-01' = {
  parent: workspace
  name: 'RASDevice_CL'
  properties: {
    totalRetentionInDays: retentionInDays
    plan: 'Analytics'
    schema: {
      name: 'RASDevice_CL'
      columns: [
        { name: 'TimeGenerated', type: 'datetime' }
        { name: 'DeviceKey', type: 'string' }
        { name: 'ClientName', type: 'string' }
        { name: 'ClientIP', type: 'string' }
        { name: 'UserName', type: 'string' }
        { name: 'OperatingSystem', type: 'string' }
        { name: 'ClientVersion', type: 'string' }
        { name: 'Vendor', type: 'string' }
        { name: 'Model', type: 'string' }
        { name: 'LastSeen', type: 'datetime' }
        { name: 'Source', type: 'string' }
      ]
    }
  }
}

// --- RASUserExperience_CL : latency, bandwidth, quality, UX evaluator ---
resource tblUserExperience 'Microsoft.OperationalInsights/workspaces/tables@2022-10-01' = {
  parent: workspace
  name: 'RASUserExperience_CL'
  properties: {
    totalRetentionInDays: retentionInDays
    plan: 'Analytics'
    schema: {
      name: 'RASUserExperience_CL'
      columns: [
        { name: 'TimeGenerated', type: 'datetime' }
        { name: 'SampleTime', type: 'datetime' }
        { name: 'MetricName', type: 'string' }
        { name: 'MetricValue', type: 'real' }
        { name: 'Unit', type: 'string' }
        { name: 'UserName', type: 'string' }
        { name: 'Computer', type: 'string' }
        { name: 'SessionId', type: 'int' }
        { name: 'SessionKey', type: 'string' }
        { name: 'Provider', type: 'string' }
        { name: 'HostPool', type: 'string' }
        { name: 'TransportProtocol', type: 'string' }
        { name: 'Source', type: 'string' }
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
output sessionHistoryStream string = 'Custom-RASSessionHistory_CL'
output applicationUsageStream string = 'Custom-RASApplicationUsage_CL'
output connectionEventStream string = 'Custom-RASConnectionEvent_CL'
output deviceStream string = 'Custom-RASDevice_CL'
output userExperienceStream string = 'Custom-RASUserExperience_CL'
output auditStream string = 'Custom-RASAudit_CL'
