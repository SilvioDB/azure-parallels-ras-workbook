# Naming convention and object map

This document is the **source of truth** for: which objects must **already exist**,
which are **created by the package**, **where** (subscription / resource group) and with
**what name**. No name is arbitrary.

## 1. Naming convention (aligned with Microsoft CAF)

Azure resource name pattern:

```
<type>-<workload>-[<purpose>-]<env>-<regionCode>
```

| Token | Values | Where it is set |
| --- | --- | --- |
| `<type>` | `dce`, `dcr` (CAF abbreviations) | fixed per resource type |
| `<workload>` | `ras` | `bicep` param `workload` |
| `<purpose>` | `ingest`, `ama` | fixed in template |
| `<env>` | `prod` \| `test` \| `dev` | `bicep` param `environment` |
| `<regionCode>` | `weu`, `neu`, `eus`, ... | `bicep` param `regionCode` |

The actual names are **computed** in `bicep/main.bicep` (section *Derived values*) from
these 3 parameters: change the tokens, and all names change consistently.

> **Exception — custom tables.** The `RAS*_CL` names **do not follow** the CAF pattern
> because they are a **contract** shared across 3 points: `tables.bicep`, `dcr-ingest.bicep`
> (`streamDeclarations`), the Workbook KQL queries, and the collector script
> (`$Tables` at the top of `Collect-RasInventory.ps1`). They must be changed **together**
> in all three places, or not changed at all.

## 2. Objects that MUST already exist (you provide these)

| Object | Type | Notes / where to specify |
| --- | --- | --- |
| Log Analytics workspace | `Microsoft.OperationalInsights/workspaces` | params `workspaceName`, `workspaceResourceGroup`, `workspaceSubscriptionId` |
| Monitoring resource group | `Microsoft.Resources/resourceGroups` | target of `az deployment group create` (hosts DCE/DCR/Workbook) |
| RAS machines (Arc and/or VM) | `Microsoft.HybridCompute/machines` / `Microsoft.Compute/virtualMachines` | param `machines[]` |
| Azure Key Vault | `Microsoft.KeyVault/vaults` | param `KeyVaultName` of the installer; secrets `ras-admin-user`, `ras-admin-password` |
| RAS admin account (read-only) | credential stored in Key Vault | see `docs/prereqs.md` |
| Collector host Managed Identity | system-assigned (Arc/VM) | param `collectorPrincipalIds[]` |

## 3. Objects CREATED by the Bicep package

All created in the **monitoring resource group** (deployment target), except the custom
tables which are created **in the workspace RG**.

| Object | Name (prod/weu example) | Type | Created in (scope) |
| --- | --- | --- | --- |
| Data Collection Endpoint | `dce-ras-prod-weu` | `Microsoft.Insights/dataCollectionEndpoints` | monitoring RG |
| DCR Logs Ingestion | `dcr-ras-prod-weu-ingest` | `Microsoft.Insights/dataCollectionRules` | monitoring RG |
| DCR Azure Monitor Agent | `dcr-ras-prod-weu-ama` | `Microsoft.Insights/dataCollectionRules` | monitoring RG |
| Server table | `RASServer_CL` | `.../workspaces/tables` | **workspace RG** |
| Agent table | `RASAgent_CL` | `.../workspaces/tables` | **workspace RG** |
| Session table | `RASSession_CL` | `.../workspaces/tables` | **workspace RG** |
| Audit table | `RASAudit_CL` | `.../workspaces/tables` | **workspace RG** |
| DCR-AMA associations | `ras-ama-dcr` (per machine) | `Microsoft.Insights/dataCollectionRuleAssociations` | scope = each machine (machine RG) |
| Role assignment | deterministic GUID | `Microsoft.Authorization/roleAssignments` | scope = DCR-ingest (monitoring RG) |
| Workbook | deterministic GUID¹ | `Microsoft.Insights/workbooks` | monitoring RG |

¹ The Workbook **resource name** must be a GUID (platform requirement):
generated deterministically with `guid(resourceGroup().id, 'ras-overview-workbook')`,
so it is stable across deployments. The human-readable **display name** is
`Parallels RAS - Infrastructure Overview` (param `displayName` in `workbook.bicep`).

### RBAC roles assigned

- **Monitoring Metrics Publisher** (`3913510d-42f4-4e42-8a64-420c390055eb`) on the collector
  host MI, **scope = DCR-ingest**. Defined in `rbac.bicep`.
- *Key Vault Secrets User* on the same MI on the Key Vault: **not** in the template (the KV
  may be external) — assigned manually, see `docs/prereqs.md`.

## 4. Objects created on the collector host

| Object | Name (default) | Where to change |
| --- | --- | --- |
| Scheduled task | `Parallels RAS - Azure Monitor Collector` | param `-TaskName` of `Install-RasCollectorTask.ps1` |
| Log file | `Collect-RasInventory.log` | param `-LogFile` of the collector |

## 5. Contract names centralised in the scripts

At the top of `collector/Collect-RasInventory.ps1`:

```powershell
$Tables = @{ Server='RASServer_CL'; Agent='RASAgent_CL'; Session='RASSession_CL'; Audit='RASAudit_CL' }
# the DCR stream is always 'Custom-<table>'
$ResourceMonitor  = 'https://monitor.azure.com'
$ResourceKeyVault = 'https://vault.azure.net'
```

Change table names **only** here **and** in `tables.bicep` + `dcr-ingest.bicep` + the
Workbook queries, keeping all four in sync.
