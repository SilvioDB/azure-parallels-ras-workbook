<#
.SYNOPSIS
    Script STANDALONE di test campi RAS (v20/v21). Da eseguire a mano sul Connection
    Broker (o su un host con la RAS Console / modulo RASAdmin).

    NON tocca Azure, NON usa Key Vault. Si connette alla farm, applica gli stessi
    mapping del collector e stampa la copertura dei campi delle 4 tabelle previste,
    evidenziando i campi SEMPRE VUOTI (probabile mapping da correggere).

    L'output viene anche salvato in .\RasFieldTest.txt (da rimandare per la verifica).

.NOTES
    Copia questo SOLO file sul server (es. C:\Temp) ed esegui in PowerShell elevato:
        Set-ExecutionPolicy -Scope Process Bypass -Force
        .\Test-RasFields.ps1                 # connette a localhost
        .\Test-RasFields.ps1 -RasServer "broker01"   # da workstation di gestione
#>
[CmdletBinding()]
param(
    [string] $RasServer = 'localhost',
    [pscredential] $RasCredential,
    [string] $FarmName = 'RAS-TEST',
    [string] $ReportFile = "$PSScriptRoot\RasFieldTest.txt"
)

$ErrorActionPreference = 'Stop'

# --- helper identici al collector ---------------------------------------------
function Get-Prop {
    param([object]$Obj, [string[]]$Names, $Default = $null)
    foreach ($n in $Names) {
        if ($null -ne $Obj -and $Obj.PSObject.Properties.Name -contains $n) {
            $v = $Obj.$n
            if ($null -ne $v -and "$v" -ne '') { return $v }
        }
    }
    return $Default
}
function Resolve-Role {
    param([string]$ServerType)
    $t = "$ServerType".Trim()
    switch -Regex ($t) {
        '^RDSHost$'                                     { return 'RDSH' }
        '^RDSGroup$'                                    { return 'RDSGroup' }
        '^RDS'                                          { return 'RDSH' }
        '^PA$|PublishingAgent|ConnectionBroker|Broker'  { return 'Broker' }
        'Gateway|^SG$|^CG$'                             { return 'Gateway' }
        'Provider'                                      { return 'Provider' }
        'AVD'                                           { return 'AVD' }
        'VDITemplate'                                   { return 'VDITemplate' }
        'VDIHostPool'                                   { return 'VDIPool' }
        'VDI'                                           { return 'VDI' }
        'HALB'                                          { return 'HALB' }
        default                                         { if ($t -ne '') { return $t } else { return 'Unknown' } }
    }
}
function Show-Coverage {
    param([string]$Name, [object[]]$Rows)
    Write-Host ""
    Write-Host ("=== {0} : {1} righe ===" -f $Name, $Rows.Count) -ForegroundColor Cyan
    if (-not $Rows -or $Rows.Count -eq 0) { Write-Host "  (nessun record)"; return }
    # Le righe sono OrderedDictionary: le chiavi dati sono in .Keys (non in PSObject.Properties)
    $keys = if ($Rows[0] -is [System.Collections.IDictionary]) { @($Rows[0].Keys) } else { $Rows[0].PSObject.Properties.Name }
    foreach ($p in $keys) {
        $nonEmpty = ($Rows | Where-Object { "$($_[$p])" -ne '' -and "$($_[$p])" -ne '0' }).Count
        $empty = ($nonEmpty -eq 0)
        $flag = if ($empty) { '  <-- SEMPRE VUOTO' } else { '' }
        Write-Host ("  {0,-18} {1}/{2}{3}" -f $p, $nonEmpty, $Rows.Count, $flag) -ForegroundColor $(if ($empty) { 'Yellow' } else { 'Gray' })
    }
    Write-Host "  -- esempio prima riga --" -ForegroundColor DarkGray
    foreach ($p in $keys) { Write-Host ("    {0,-18} = {1}" -f $p, $Rows[0][$p]) }
}

Start-Transcript -Path $ReportFile -Force | Out-Null
try {
    Write-Host "Modulo RASAdmin:" -ForegroundColor Green
    Get-Module -ListAvailable RASAdmin | Select-Object Name, Version | Format-Table | Out-String | Write-Host
    Import-Module RASAdmin -ErrorAction Stop

    if (-not $RasCredential) { $RasCredential = Get-Credential -Message "Credenziali admin RAS" }

    Write-Host "Connessione a $RasServer ..." -ForegroundColor Green
    New-RASSession -Server $RasServer -Username $RasCredential.UserName -Password $RasCredential.Password | Out-Null
    try { Write-Host ("RAS Version: {0}" -f ((Get-RASVersion | Out-String).Trim())) } catch {}

    $now = (Get-Date).ToUniversalTime().ToString('o')

    # mappa SiteId -> Name
    $siteMap = @{}
    try { Get-RASSite | ForEach-Object { $siteMap["$(Get-Prop $_ @('Id'))"] = "$(Get-Prop $_ @('Name'))" } } catch { Write-Warning "Get-RASSite: $($_.Exception.Message)" }
    function Resolve-Site { param($SiteId) $k = "$SiteId"; if ($siteMap.ContainsKey($k)) { $siteMap[$k] } else { $k } }

    # --- RASServer_CL + RASAgent_CL da Get-RASAgent ---
    $serverRows = @(); $agentRows = @()
    try {
        Get-RASAgent | ForEach-Object {
            $rawType = "$(Get-Prop $_ @('ServerType','Type') '')"
            if ($rawType -eq 'Site') { return }   # oggetto Site RAS, non e' un server monitorabile
            $site = Resolve-Site (Get-Prop $_ @('SiteId'))
            $serverRows += [ordered]@{
                TimeGenerated = $now
                Computer      = "$(Get-Prop $_ @('Server','Name'))"
                FarmName      = $FarmName
                SiteName      = $site
                Role          = Resolve-Role $rawType
                ServerStatus  = "$(Get-Prop $_ @('AgentState','State') 'Unknown')"
                AgentVersion  = "$(Get-Prop $_ @('AgentVer','AgentVersion','Version') '')"
                OSVersion     = "$(Get-Prop $_ @('ServerOS','OSVersion','OS') '')"
                IPAddress     = "$(Get-Prop $_ @('IP','IPAddress','DirectAddress') '')"
                Enabled       = [bool](Get-Prop $_ @('Enabled') $true)
            }
            $agentRows += [ordered]@{
                TimeGenerated = $now
                Computer      = "$(Get-Prop $_ @('Server','Name'))"
                SiteName      = $site
                AgentType     = $rawType
                AgentState    = "$(Get-Prop $_ @('AgentState','State') '')"
                AgentVersion  = "$(Get-Prop $_ @('AgentVer','AgentVersion','Version') '')"
                OSVersion     = "$(Get-Prop $_ @('ServerOS','OSVersion','OS') '')"
            }
        }
    } catch { Write-Warning "Get-RASAgent: $($_.Exception.Message)" }

    # --- RASSession_CL da Get-RASRDSession -Source All ---
    $sessionRows = @()
    try {
        Get-RASRDSession -Source All | ForEach-Object {
            $logon = Get-Prop $_ @('LogonTime')
            $sessionRows += [ordered]@{
                TimeGenerated     = $now
                Computer          = "$(Get-Prop $_ @('SessionHostName','ServerName','HostName'))"
                SessionId         = [int](Get-Prop $_ @('SessionID','SessionId','Id') 0)
                UserName          = "$(Get-Prop $_ @('User','UserName') '')"
                ClientName        = "$(Get-Prop $_ @('DeviceName','ClientName') '')"
                ClientIP          = "$(Get-Prop $_ @('ClientIPAddress','ClientIP','IP') '')"
                SessionState      = "$(Get-Prop $_ @('State','SessionState') '')"
                SessionType       = "$(Get-Prop $_ @('Source','SessionType') 'RDS')"
                LogonTime         = if ($logon) { try { ([datetime]$logon).ToUniversalTime().ToString('o') } catch { '' } } else { '' }
                IdleTimeSec       = [int](Get-Prop $_ @('IdleTime','IdleSeconds') 0)
                PublishedResource = "$(Get-Prop $_ @('PoolName','TemplateName','PublishedName') '')"
            }
        }
    } catch { Write-Warning "Get-RASRDSession: $($_.Exception.Message)" }

    # --- RASAudit_CL da Get-RASAdminSession (UserId risolto via Get-RASAdminAccount) ---
    $adminMap = @{}
    try { Get-RASAdminAccount | ForEach-Object { $adminMap["$(Get-Prop $_ @('Id'))"] = "$(Get-Prop $_ @('Name','Account','UserName','Email') '')" } } catch { Write-Warning "Get-RASAdminAccount: $($_.Exception.Message)" }

    $auditRows = @()
    try {
        Get-RASAdminSession | ForEach-Object {
            $uid = "$(Get-Prop $_ @('UserId','AdminId') '')"
            $aname = if ($uid -and $adminMap.ContainsKey($uid) -and $adminMap[$uid]) { $adminMap[$uid] } else { "$(Get-Prop $_ @('ComputerName') '')" }
            $auditRows += [ordered]@{
                TimeGenerated = $now
                AdminUser     = $aname
                Action        = 'AdminConsoleSession'
                ObjectType    = 'AdminSession'
                ObjectName    = "$(Get-Prop $_ @('ComputerName') '')"
                Result        = "$(Get-Prop $_ @('State') '')"
                ClientIP      = "$(Get-Prop $_ @('IP') '')"
                Source        = 'AdminSession'
            }
        }
    } catch { Write-Warning "Get-RASAdminSession: $($_.Exception.Message)" }

    Show-Coverage -Name 'RASServer_CL'  -Rows $serverRows
    Show-Coverage -Name 'RASAgent_CL'   -Rows $agentRows
    Show-Coverage -Name 'RASSession_CL' -Rows $sessionRows
    Show-Coverage -Name 'RASAudit_CL'   -Rows $auditRows

    # Dump grezzo del PRIMO oggetto di ogni cmdlet (per scoprire i nomi reali se qualcosa manca)
    Write-Host "`n========== DUMP GREZZO PRIMA RIGA PER CMDLET ==========" -ForegroundColor Magenta
    foreach ($pair in @(
        @{ n='Get-RASAgent';            c={ Get-RASAgent } },
        @{ n='Get-RASRDSession -Source All'; c={ Get-RASRDSession -Source All } },
        @{ n='Get-RASAdminSession';     c={ Get-RASAdminSession } },
        @{ n='Get-RASAdminAccount';     c={ Get-RASAdminAccount } }
    )) {
        Write-Host "`n--- $($pair.n) ---" -ForegroundColor Magenta
        try {
            $o = & $pair.c | Select-Object -First 1
            if ($o) { ($o | Format-List * | Out-String).Trim() | Write-Host } else { Write-Host "(nessun oggetto)" }
        } catch { Write-Warning $_.Exception.Message }
    }
}
finally {
    try { Remove-RASSession -ErrorAction SilentlyContinue } catch {}
    Stop-Transcript | Out-Null
    Write-Host "`nReport salvato in: $ReportFile" -ForegroundColor Green
}
