# Prerequisites and setup

Operational guide for the steps to complete **before** and **after** deploying the package.

## 1. Agent onboarding (Pipeline A — Perf/Event)

### On-premises servers → Azure Arc

```powershell
# On each on-prem RAS server (download azcmagent from the Arc portal)
azcmagent connect `
  --resource-group "rg-ras-prod-weu" `
  --tenant-id "<TENANT_ID>" `
  --location "westeurope" `
  --subscription-id "<SUB_ID>"
```
Onboarding creates the **system-assigned managed identity** (local endpoint `localhost:40342`).

### Azure VM
System identity is already available via IMDS (`169.254.169.254`). Enable it if missing:
```powershell
az vm identity assign --name "RAS-RDS-12" --resource-group "rg-ras-prod-weu"
```

### Azure Monitor Agent
The Azure Connected Machine agent and the Azure Monitor Agent are separate components.
The Bicep deployment creates the DCR association but does not declare the AMA extension.
Install AMA on every monitored server beforehand, or use Azure Policy to enforce it:
```powershell
# Arc
az connectedmachine extension create -g rg-ras-prod-weu --machine-name RAS-CB-01 `
  -n AzureMonitorWindowsAgent --publisher Microsoft.Azure.Monitor `
  --type AzureMonitorWindowsAgent
# Azure VM
az vm extension set -g rg-ras-prod-weu --vm-name RAS-RDS-12 `
  -n AzureMonitorWindowsAgent --publisher Microsoft.Azure.Monitor
```

## 2. Collector host (Pipeline B — RAS data)

Choose **one** host (Connection Broker or host with RAS Console) that:

- has the **RAS PowerShell module** (`RASAdmin`) installed (included with RAS Console);
- is **Arc-enabled** or an **Azure VM** (for the managed identity);
- can reach the RAS farm and the endpoints `*.ingest.monitor.azure.com` and `*.vault.azure.net`.

Verify the module:
```powershell
Get-Module -ListAvailable RASAdmin
Import-Module RASAdmin; (Get-Command New-RASSession, Get-RASAgent, Get-RASRDSession)
```

## 3. Key Vault with RAS credentials

```powershell
az keyvault secret set --vault-name "kv-ras-prod" --name "ras-admin-user"     --value "DOMAIN\\svc-ras-ro"
az keyvault secret set --vault-name "kv-ras-prod" --name "ras-admin-password" --value "<password>"
```
Grant the **collector host managed identity** the *Key Vault Secrets User* role:
```powershell
$principalId = "<object ID of the collector host MI>"
az role assignment create --assignee-object-id $principalId --assignee-principal-type ServicePrincipal `
  --role "Key Vault Secrets User" `
  --scope "/subscriptions/<SUB>/resourceGroups/<RG>/providers/Microsoft.KeyVault/vaults/kv-ras-prod"
```
> Use a **read-only RAS admin account** for collection where possible.

## 4. Retrieve principalIds for the `collectorPrincipalIds` parameter

```powershell
# Arc
az connectedmachine show -g rg-ras-prod-weu -n RAS-CB-01 --query "identity.principalId" -o tsv
# Azure VM
az vm show -g rg-ras-prod-weu -n RAS-RDS-12 --query "identity.principalId" -o tsv
```
Add these values to `bicep/main.parameters.json` → `collectorPrincipalIds`
(Bicep assigns *Monitoring Metrics Publisher* on the DCR-Ingest).

## 5. After the deploy

From the deployment output, retrieve `dceLogsIngestionEndpoint` and `dcrIngestImmutableId`:
```powershell
az deployment group show -g rg-monitoring-weu -n main `
  --query "properties.outputs.{dce:dceLogsIngestionEndpoint.value, dcr:dcrIngestImmutableId.value}"
```
Then install the task on the collector host (elevated PowerShell):
```powershell
.\collector\Install-RasCollectorTask.ps1 `
  -DceLogsIngestionUri "<dce>" -DcrImmutableId "<dcr>" -KeyVaultName "kv-ras-prod" `
  -ComputerNameStyle FQDN -DnsDomain "corp.local"
```

## 6. Performance counters collected (DCR-AMA)

| Object | Counters |
| --- | --- |
| Processor Information(_Total) | % Processor Time, % User Time, % Privileged Time |
| Memory | % Committed Bytes In Use, Available MBytes, Pages/sec, Page Faults/sec |
| LogicalDisk(_Total) | % Free Space, Free Megabytes, Disk Reads/Writes/Transfers/sec, Avg. Disk sec/Read-Write |
| Network Interface(*) | Bytes Total/sec, Packets Received Errors |
| System | Processor Queue Length, System Up Time |
| Terminal Services | Active / Inactive / Total Sessions |
| Process(_Total) | Working Set, Handle Count, Thread Count |
| Parallels RAS Connection Broker | Client connection, authentication, policy, telemetry, published-item/icon and request-start average times |
| Parallels RAS Secure Gateway | Connections and protocol distribution, total/idle threads, cached sockets |
| Parallels RAS RDS Agent | Active and disconnected RDS sessions |

Native RAS counter sets are present only on servers where the corresponding component is
installed. Confirm their exact Windows paths before deployment:

```powershell
Get-Counter -ListSet '*Parallels*' |
  Select-Object CounterSetName, Paths
```

The native Gateway `Total connections` value is cumulative in the tested RAS 21 environment;
the Workbook displays its positive delta per 5-minute interval. Connection Broker average-time
counters remain in their native unit because the Parallels documentation does not specify one.

> **`Computer` name alignment**: AMA writes `Computer` in `Perf`/`Event` as reported by
> the OS (often FQDN). The collector script normalises with `-ComputerNameStyle` to ensure
> KQL joins in the Workbook match. Verify with:
> `Perf | distinct Computer` vs `RASServer_CL | distinct Computer`.

## 7. Ingestion verification

```kusto
RASServer_CL  | summarize max(TimeGenerated)
RASAgent_CL   | take 10
RASSession_CL | summarize count() by SessionState
RASAudit_CL   | take 10
Perf  | where TimeGenerated > ago(15m) | summarize count() by Computer
Event | where TimeGenerated > ago(1h)  | summarize count() by EventLevelName
Perf  | where TimeGenerated > ago(1h) | where ObjectName startswith "Parallels RAS" | summarize count() by Computer, ObjectName, CounterName
```
(First data in a new custom table can take ~10–15 min to appear.)
