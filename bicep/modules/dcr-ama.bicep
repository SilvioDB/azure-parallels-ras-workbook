// DCR for Azure Monitor Agent (Pipeline A).
// Collects performance counters (-> Perf) and Windows Event Logs (-> Event)
// from RAS servers (session hosts and other roles). kind: Windows.

@description('Nome della DCR AMA.')
param dcrName string

@description('Region (deve coincidere con workspace).')
param location string

@description('Resource ID del Log Analytics workspace.')
param workspaceResourceId string

@description('Frequenza di campionamento dei perf counter (secondi).')
param samplingFrequencyInSeconds int = 60

resource dcr 'Microsoft.Insights/dataCollectionRules@2023-03-11' = {
  name: dcrName
  location: location
  kind: 'Windows'
  properties: {
    dataSources: {
      performanceCounters: [
        {
          name: 'perfCommon'
          streams: [ 'Microsoft-Perf' ]
          samplingFrequencyInSeconds: samplingFrequencyInSeconds
          counterSpecifiers: [
            '\\Processor Information(_Total)\\% Processor Time'
            '\\Processor Information(_Total)\\% User Time'
            '\\Processor Information(_Total)\\% Privileged Time'
            '\\Memory\\% Committed Bytes In Use'
            '\\Memory\\Available MBytes'
            '\\Memory\\Pages/sec'
            '\\Memory\\Page Faults/sec'
            '\\LogicalDisk(_Total)\\% Free Space'
            '\\LogicalDisk(_Total)\\Free Megabytes'
            '\\LogicalDisk(_Total)\\Disk Reads/sec'
            '\\LogicalDisk(_Total)\\Disk Writes/sec'
            '\\LogicalDisk(_Total)\\Disk Transfers/sec'
            '\\LogicalDisk(_Total)\\Avg. Disk sec/Read'
            '\\LogicalDisk(_Total)\\Avg. Disk sec/Write'
            '\\Network Interface(*)\\Bytes Total/sec'
            '\\Network Interface(*)\\Packets Received Errors'
            '\\System\\Processor Queue Length'
            '\\System\\System Up Time'
          ]
        }
        {
          // Counters typical of RDS Session Hosts. On servers without RDS they will simply be absent.
          name: 'perfRds'
          streams: [ 'Microsoft-Perf' ]
          samplingFrequencyInSeconds: samplingFrequencyInSeconds
          counterSpecifiers: [
            '\\Terminal Services\\Active Sessions'
            '\\Terminal Services\\Inactive Sessions'
            '\\Terminal Services\\Total Sessions'
            '\\Process(_Total)\\Working Set'
            '\\Process(_Total)\\Handle Count'
            '\\Process(_Total)\\Thread Count'
          ]
        }
        {
          // Native counters registered by Parallels RAS components. Keeping them in a
          // dedicated source prevents product experience/capacity from being confused
          // with Windows and Terminal Services health in the Workbook.
          // Counters absent from a machine role are ignored by AMA.
          name: 'perfRas'
          streams: [ 'Microsoft-Perf' ]
          samplingFrequencyInSeconds: samplingFrequencyInSeconds
          counterSpecifiers: [
            '\\Parallels RAS Connection Broker\\Average time for client connection'
            '\\Parallels RAS Connection Broker\\Average time for user authentication'
            '\\Parallels RAS Connection Broker\\Average time to retrieve user policy'
            '\\Parallels RAS Connection Broker\\Average time to send client telemetry'
            '\\Parallels RAS Connection Broker\\Average time to retrieve user\'s published items'
            '\\Parallels RAS Connection Broker\\Average time to retrieve icons'
            '\\Parallels RAS Connection Broker\\Average time to start up a request'

            '\\Parallels RAS Secure Gateway\\Total connections'
            '\\Parallels RAS Secure Gateway\\Total threads'
            '\\Parallels RAS Secure Gateway\\RDP tunneled sessions'
            '\\Parallels RAS Secure Gateway\\RDP SSL tunneled sessions'
            '\\Parallels RAS Secure Gateway\\HTTP connections'
            '\\Parallels RAS Secure Gateway\\HTTPS connections'
            '\\Parallels RAS Secure Gateway\\HTML5 connections'
            '\\Parallels RAS Secure Gateway\\HTML5 SSL connections'
            '\\Parallels RAS Secure Gateway\\Device Manager connections'
            '\\Parallels RAS Secure Gateway\\Device Manager SSL connections'
            '\\Parallels RAS Secure Gateway\\Wyse connections'
            '\\Parallels RAS Secure Gateway\\Wyse SSL connections'
            '\\Parallels RAS Secure Gateway\\RDP UDP tunneled sessions'
            '\\Parallels RAS Secure Gateway\\RDP UDP DTLS tunneled sessions'
            '\\Parallels RAS Secure Gateway\\Cached sockets'
            '\\Parallels RAS Secure Gateway\\Idle threads'
            '\\Parallels RAS Secure Gateway\\Client connections'
            '\\Parallels RAS Secure Gateway\\Client SSL connections'

            '\\Parallels RAS RDS Agent\\Active RDS sessions'
            '\\Parallels RAS RDS Agent\\Disconnected RDS sessions'
          ]
        }
      ]
      windowsEventLogs: [
        {
          // Parallels RAS events only. Add entries for new components/providers
          // discovered via Event Viewer -> Applications and Services Logs or eventvwr.msc.
          // Legacy provider "2X Remote Application Server" included for farms upgraded from RAS <19.
          name: 'rasEvents'
          streams: [ 'Microsoft-Event' ]
          xPathQueries: [
            'Application!*[System[Provider[@Name=\'Parallels RAS\']]]'
            'Application!*[System[Provider[@Name=\'Parallels RAS Publishing Agent\']]]'
            'Application!*[System[Provider[@Name=\'Parallels RAS Secure Gateway\']]]'
            'Application!*[System[Provider[@Name=\'Parallels RAS RD Session Host Agent\']]]'
            'Application!*[System[Provider[@Name=\'Parallels RAS Terminal Server Agent\']]]'
            'Application!*[System[Provider[@Name=\'Parallels Client Manager\']]]'
            'Application!*[System[Provider[@Name=\'Parallels RAS HALB\']]]'
            'Application!*[System[Provider[@Name=\'2X Remote Application Server\']]]'
          ]
        }
        {
          // Terminal Services session lifecycle events on RDSH hosts.
          // Complements RASSession_CL (API polling) with exact logon/logoff timestamps.
          // EventID 21=logon, 23=logoff, 24=disconnect, 25=reconnect, 40=disconnect+reason.
          name: 'tsSessionEvents'
          streams: [ 'Microsoft-Event' ]
          xPathQueries: [
            'Microsoft-Windows-TerminalServices-LocalSessionManager/Operational!*[System[(EventID=21 or EventID=23 or EventID=24 or EventID=25 or EventID=40)]]'
          ]
        }
      ]
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
        streams: [ 'Microsoft-Perf' ]
        destinations: [ 'laDest' ]
      }
      {
        streams: [ 'Microsoft-Event' ]
        destinations: [ 'laDest' ]
      }
    ]
  }
}

output id string = dcr.id
