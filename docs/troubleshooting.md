# Troubleshooting

Known issues and solutions encountered during deployment and operations.

---

## Performance tab — "The query returned no results"

**Cause**: `Perf` data comes from Azure Monitor Agent (Pipeline A), not from Parallels RAS.
AMA takes **10–20 minutes** to pick up a new DCR association and start sending data to the
workspace.

**Check**:
```kusto
Perf
| where TimeGenerated > ago(1h)
| summarize count() by Computer, ObjectName
| order by Computer asc
```
If the query returns rows, the pipeline is working — the workbook time range was too narrow.
If empty, proceed with the checks below.

**Check 1 — AMA service status** (elevated PowerShell on the server):
```powershell
Get-Service -Name AzureMonitorAgent | Select-Object Name, Status

Get-Content "C:\WindowsAzure\Logs\Plugins\Microsoft.Azure.Monitor.AzureMonitorWindowsAgent\*\AzureMonitorAgent*.log" -Tail 30
```

**Check 2 — DCR association in the portal**:
Azure Arc → [server] → **Extensions** → `AzureMonitorWindowsAgent` must be `Succeeded`.
Azure Arc → [server] → **Data Collection Rules** → `dcr-ras-prod-weu-ama` must appear.

**Check 3 — Force AMA reinstall** (if status is `Failed`):
```powershell
az connectedmachine extension delete `
  --machine-name <server> --resource-group <resource-group> `
  --name AzureMonitorWindowsAgent --yes

az connectedmachine extension create `
  --machine-name <server> --resource-group <resource-group> `
  --name AzureMonitorWindowsAgent `
  --type AzureMonitorWindowsAgent `
  --publisher Microsoft.Azure.Monitor `
  --location westeurope
```

> **Note**: if only some servers out of N are sending data, this is normal in the first
> 30 minutes after deploy. Propagation happens at different times per machine.

---

## Computer name mismatch — empty Perf ↔ RASServer_CL join

**Symptom**: Performance tab is empty even though `Perf` has data.

**Cause**: AMA writes `Computer` as FQDN (e.g. `server01.corp.local`), but the RAS
collector uses the short name (e.g. `server01`), or vice versa.

**Check**:
```kusto
Perf | where TimeGenerated > ago(1h) | distinct Computer
RASServer_CL | summarize arg_max(TimeGenerated,*) by Computer | distinct Computer
```
Values in the `Computer` column must match exactly.

**Fix**: reinstall the task with the correct parameter:
```powershell
.\Install-RasCollectorTask.ps1 ... -ComputerNameStyle FQDN -DnsDomain "corp.local"
# or
.\Install-RasCollectorTask.ps1 ... -ComputerNameStyle Host
```

---

## RASAudit_CL — 0 rows / "insufficient permissions"

**Cause**: `Get-RASAdminAccount` and `Get-RASAdminSession` require the full
**RAS Administrator** role. An account with a custom role (even with all View entries
enabled) is not sufficient.

**Fix**: promote the collector service account to **RAS Administrator** in the RAS portal:
Administration → Administrators → [account] → Role: RAS Administrator.

> Risk is contained: the account is dedicated and the password is in Key Vault. The
> collector never performs write operations on the farm.

---

## Scheduled task — XML Duration error on registration

**Error**:
```
Register-ScheduledTask : The task XML contains a value which is incorrectly formatted
or out of range. (10,42):Duration:P99999999DT23H59M59S
```

**Cause**: `[TimeSpan]::MaxValue` is not accepted by the Windows Task Scheduler XML.

**Fix**: already resolved in the current version of `Install-RasCollectorTask.ps1`
(`-RepetitionDuration` removed; on Windows Server 2012+ repetition is indefinite
by default with `-Once` + `-RepetitionInterval`).

---

## Key Vault — Forbidden when creating secrets

**Error**: `(Forbidden) Caller is not authorized to perform action... setSecret/action`

**Cause**: the Key Vault uses pure RBAC (`enableRbacAuthorization: true`). The user
running the deploy does not automatically have the role to write secrets.

**Fix**: assign **Key Vault Secrets Officer** to the user/service principal that needs
to create or update secrets:
```powershell
az role assignment create `
  --role "Key Vault Secrets Officer" `
  --assignee "<user-object-id>" `
  --scope "/subscriptions/<SUB>/resourceGroups/<RG>/providers/Microsoft.KeyVault/vaults/<kv-name>"
```
Alternatively, create secrets manually in the Azure portal:
Key Vault → Objects → Secrets → **Generate/Import**.

---

## DCR — region error (Arc in westeurope, workspace in a different region)

**Symptom**: AMA sends data but the workspace does not receive it, or validation errors
occur when creating the DCR.

**Cause**: Microsoft requires the DCR to be in the same region as the Azure Arc servers.
If the workspace is in a different region (e.g. `italynorth`), the DCR must still be in
`westeurope` (co-located with Arc). Cross-region DCR→workspace works but can cause
instability.

**Fix**: keep `location: westeurope` in the Bicep parameter if the Arc servers are in
West Europe, regardless of the workspace region.

---

## Role definition ID — "does not exist"

**Error**: `The specified role definition with ID '...' does not exist`

**Cause**: built-in Azure role GUIDs differ between tenants/clouds (Azure Commercial,
Azure Government, etc.).

**Fix**: verify the actual GUID in your subscription before deploying:
```powershell
az role definition list --name "Key Vault Secrets User" `
  --subscription <SUB_ID> --query "[].name" -o tsv

az role definition list --name "Monitoring Metrics Publisher" `
  --subscription <SUB_ID> --query "[].name" -o tsv
```
Update the values in `bicep/modules/keyvault.bicep` and `bicep/modules/rbac.bicep`.

---

## Custom tables — latency on first ingestion

**Symptom**: the collector runs successfully but `RAS*_CL` tables do not appear in
Log Analytics.

**Cause**: when a custom table is created for the first time, Azure Monitor takes
**5–15 minutes** to make it available for ingestion.

**Fix**: wait and re-run the collector. Verify:
```kusto
RASServer_CL | take 1
```
