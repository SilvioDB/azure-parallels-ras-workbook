<#
.SYNOPSIS
    Raccoglie inventario, sessioni, agent e audit da una farm Parallels RAS (v20 -> v21)
    e li pubblica su Azure Monitor Logs (custom tables) via Logs Ingestion API.

.DESCRIPTION
    Pipeline B del pacchetto "Azure Workbook per Parallels RAS".
    - Ottiene un token Microsoft Entra tramite Managed Identity dell'host:
      auto-rileva Azure Arc (IDENTITY_ENDPOINT, challenge token) oppure Azure VM (IMDS).
    - Legge le credenziali admin RAS da Azure Key Vault (con la stessa MI).
    - Si connette alla farm (New-RASSession) e raccoglie i dati con i cmdlet RAS.
    - Invia gli stream JSON alla Logs Ingestion API.

    Campi RAS verificati sulla documentazione PowerShell API v20 (stabili anche in v21):
      Get-RASAgent      -> *SysInfo: Server, ServerType, AgentState, AgentVer, ServerOS, SiteId, IP, Enabled, CPULoad, MemLoad, ActiveSessions
      Get-RASRDSession  -> RDSession: SessionID, User, DeviceName, ClientIPAddress, State, LogonTime, SessionHostName, IdleTime, Source, Type, PoolName
      Get-RASAdminSession -> AdminSession: ComputerName, IP, LogonTime, State (NB: nessun username admin)
      Get-RASSite       -> Id, Name (mappa SiteId -> nome sito)

.NOTES
    Eseguire come scheduled task (vedi Install-RasCollectorTask.ps1) su un host RAS
    (Connection Broker / RAS Console) con il modulo PowerShell RAS (RASAdmin).
#>

[CmdletBinding()]
param(
    # --- Endpoint Azure Monitor (output del deployment Bicep; richiesti se NON -DryRun) ---
    [string] $DceLogsIngestionUri,
    [string] $DcrImmutableId,

    # --- Key Vault per le credenziali RAS (alternativa: -RasCredential) ---
    [string] $KeyVaultName,
    [string] $RasUserSecretName     = 'ras-admin-user',
    [string] $RasPasswordSecretName = 'ras-admin-password',

    # --- Connessione farm RAS ---
    [string] $RasServer = 'localhost',
    [pscredential] $RasCredential,   # se fornita, bypassa Key Vault (utile in test/-DryRun)
    [string] $FarmName  = '',   # etichetta logica della farm (RAS non espone un nome farm per-server)

    # --- TEST: scrive i payload su file invece di pubblicarli su Azure ---
    [switch] $DryRun,
    [string] $OutDir = "$PSScriptRoot\out",

    # --- Normalizzazione nome computer per join con la tabella Perf di AMA ---
    [ValidateSet('AsIs','FQDN','Host')] [string] $ComputerNameStyle = 'AsIs',
    [string] $DnsDomain = '',

    # --- Identity (optional override for user-assigned MI) ---
    [string] $ManagedIdentityClientId = '',

    [string] $LogFile = "$PSScriptRoot\Collect-RasInventory.log",
    [string] $StateFile = "$PSScriptRoot\Collect-RasInventory.state.json"
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$defaultStateFile = Join-Path $PSScriptRoot 'Collect-RasInventory.state.json'
if ($DryRun -and $StateFile -eq $defaultStateFile) {
    $StateFile = Join-Path $OutDir 'Collect-RasInventory.state.json'
}

# ===========================================================================
#  NOMI OGGETTI (centralizzati - modificabili qui)
#  NB: i nomi delle tabelle DEVONO combaciare con:
#      - bicep/modules/tables.bicep e dcr-ingest.bicep (streamDeclarations)
#      - le query KQL del Workbook (workbook/ras-overview.workbook.json)
#  Non cambiarli isolatamente. Vedi docs/naming.md.
# ===========================================================================
$Tables = @{
    Server         = 'RASServer_CL'
    Agent          = 'RASAgent_CL'
    Session        = 'RASSession_CL'
    SessionHistory = 'RASSessionHistory_CL'
    Audit          = 'RASAudit_CL'
}
function Get-StreamName { param([string]$Table) "Custom-$Table" }   # convenzione DCR custom stream

# Risorse Azure target per i token
$ResourceMonitor  = 'https://monitor.azure.com'
$ResourceKeyVault = 'https://vault.azure.net'
$KeyVaultApiVer   = '7.4'
$IngestApiVer     = '2023-01-01'

# ===========================================================================
#  Logging
# ===========================================================================
function Write-Log {
    param([string]$Message, [ValidateSet('INFO','WARN','ERROR')] [string]$Level = 'INFO')
    $line = "{0} [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Write-Host $line
    try { Add-Content -Path $LogFile -Value $line -ErrorAction SilentlyContinue } catch {}
}

# ===========================================================================
#  Token via Managed Identity (auto-detect Arc vs Azure VM/IMDS)
# ===========================================================================
function Get-MsiAccessToken {
    param([Parameter(Mandatory)][string] $Resource)

    $arcEndpoint = $env:IDENTITY_ENDPOINT   # presente solo su host Azure Arc
    $clientQs = if ($ManagedIdentityClientId) { "&client_id=$ManagedIdentityClientId" } else { '' }

    if ($arcEndpoint) {
        # --- Azure Arc: flusso challenge-token ---
        $uri = "$arcEndpoint`?api-version=2020-06-01&resource=$([uri]::EscapeDataString($Resource))$clientQs"
        try {
            Invoke-WebRequest -Uri $uri -Headers @{ Metadata = 'true' } -UseBasicParsing | Out-Null
            throw "Risposta inattesa dall'endpoint Arc (atteso 401 con challenge)."
        }
        catch {
            $resp = $_.Exception.Response
            if (-not $resp) { throw "Endpoint Arc non raggiungibile: $($_.Exception.Message)" }
            $wwwAuth = $resp.Headers['WWW-Authenticate']
            if (-not $wwwAuth) { throw "Header WWW-Authenticate assente dall'endpoint Arc." }
            $secretFile = ($wwwAuth -split 'realm=', 2)[-1].Trim()   # 'Basic realm=<percorso>'
            if (-not (Test-Path $secretFile)) { throw "Challenge token non trovato: $secretFile" }
            $secret = (Get-Content -Path $secretFile -Raw).Trim()
            $tok = Invoke-RestMethod -Uri $uri -Headers @{ Metadata = 'true'; Authorization = "Basic $secret" } -UseBasicParsing
            return $tok.access_token
        }
    }
    else {
        # --- Azure VM: IMDS ---
        $uri = "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=$([uri]::EscapeDataString($Resource))$clientQs"
        $tok = Invoke-RestMethod -Uri $uri -Headers @{ Metadata = 'true' } -UseBasicParsing
        return $tok.access_token
    }
}

# ===========================================================================
#  Key Vault (REST)
# ===========================================================================
function Get-KeyVaultSecretValue {
    param([Parameter(Mandatory)][string] $VaultName, [Parameter(Mandatory)][string] $SecretName)
    $kvToken = Get-MsiAccessToken -Resource $ResourceKeyVault
    $uri = "https://$VaultName.vault.azure.net/secrets/$SecretName`?api-version=$KeyVaultApiVer"
    (Invoke-RestMethod -Uri $uri -Headers @{ Authorization = "Bearer $kvToken" } -UseBasicParsing).value
}

# ===========================================================================
#  POST di uno stream alla Logs Ingestion API
# ===========================================================================
function Send-LogStream {
    param(
        [Parameter(Mandatory)][string] $Stream,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Rows,
        [string] $MonitorToken = ''
    )
    if (-not $Rows -or $Rows.Count -eq 0) { Write-Log "Stream ${Stream}: 0 righe, skip."; return }

    if ($DryRun) {
        $file = Join-Path $OutDir "$Stream.json"
        ConvertTo-Json -InputObject @($Rows) -Depth 6 | Set-Content -Path $file -Encoding UTF8
        Write-Log "DRY-RUN ${Stream}: scritte $($Rows.Count) righe in $file"
        return
    }

    $uri = "$DceLogsIngestionUri/dataCollectionRules/$DcrImmutableId/streams/$Stream`?api-version=$IngestApiVer"
    $headers = @{ Authorization = "Bearer $MonitorToken"; 'Content-Type' = 'application/json' }

    for ($i = 0; $i -lt $Rows.Count; $i += 500) {   # batch max 500 righe
        $batch = $Rows[$i..([Math]::Min($i + 499, $Rows.Count - 1))]
        $body = ConvertTo-Json -InputObject @($batch) -Depth 6 -Compress
        Invoke-RestMethod -Uri $uri -Method Post -Headers $headers -Body $body -UseBasicParsing | Out-Null
    }
    Write-Log "Stream ${Stream}: inviate $($Rows.Count) righe."
}

# ===========================================================================
#  Helper
# ===========================================================================
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

function Resolve-ComputerName {
    param([string]$Name)
    if (-not $Name) { return $Name }
    switch ($ComputerNameStyle) {
        'FQDN' { if ($DnsDomain -and ($Name -notlike '*.*')) { return "$Name.$DnsDomain".ToLower() } else { return $Name.ToLower() } }
        'Host' { return ($Name -split '\.')[0].ToLower() }
        default { return $Name.ToLower() }
    }
}

# Normalizza RASServerType -> ruolo canonico usato dal Workbook.
# Valori RAS reali verificati su farm v21: PA, Gateway, RDSHost, RDSGroup, Provider, VDITemplate, VDIHostPool, Site.
# 'Site' deve essere filtrato PRIMA di chiamare Resolve-Role (non e' un server monitorabile).
function Resolve-Role {
    param([string]$ServerType)
    $t = "$ServerType".Trim()
    switch -Regex ($t) {
        '^RDSHost$'                                     { return 'RDSH' }        # session host fisico
        '^RDSGroup$'                                    { return 'RDSGroup' }    # pool/gruppo logico RDS
        '^RDS'                                          { return 'RDSH' }        # altre varianti RDS
        '^PA$|PublishingAgent|ConnectionBroker|Broker'  { return 'Broker' }      # PA = Publishing Agent
        'Gateway|^SG$|^CG$'                             { return 'Gateway' }
        'Provider'                                      { return 'Provider' }
        'AVD'                                           { return 'AVD' }
        'VDITemplate'                                   { return 'VDITemplate' } # immagine master VDI
        'VDIHostPool'                                   { return 'VDIPool' }     # pool VDI
        'VDI'                                           { return 'VDI' }
        'HALB'                                          { return 'HALB' }
        default                                         { if ($t -ne '') { return $t } else { return 'Unknown' } }
    }
}

function ConvertTo-IsoUtc {
    param($Value)
    if (-not $Value) { return $null }
    try { return ([datetime]$Value).ToUniversalTime().ToString('o') } catch { return $null }
}

function ConvertFrom-IsoUtc {
    param($Value)
    if (-not $Value) { return $null }
    try { return ([datetime]$Value).ToUniversalTime() } catch { return $null }
}

function Get-RowValue {
    param($Row, [string]$Name, $Default = '')
    if ($null -eq $Row) { return $Default }
    if ($Row -is [System.Collections.IDictionary]) {
        if ($Row.Contains($Name) -and $null -ne $Row[$Name]) { return $Row[$Name] }
        return $Default
    }
    if ($Row.PSObject.Properties.Name -contains $Name) {
        $v = $Row.$Name
        if ($null -ne $v) { return $v }
    }
    return $Default
}

function Get-SessionKey {
    param($Row)
    $computer = "$(Get-RowValue $Row 'Computer')".ToLowerInvariant()
    $sessionId = "$(Get-RowValue $Row 'SessionId' 0)"
    $logonTime = "$(Get-RowValue $Row 'LogonTime')"
    $userName = "$(Get-RowValue $Row 'UserName')".ToLowerInvariant()
    return "$computer|$sessionId|$logonTime|$userName"
}

function Get-DurationSeconds {
    param($Start, $End)
    $startDt = ConvertFrom-IsoUtc $Start
    $endDt = ConvertFrom-IsoUtc $End
    if ($null -eq $startDt -or $null -eq $endDt) { return 0 }
    return [int][Math]::Max(0, ($endDt - $startDt).TotalSeconds)
}

function Get-SessionHistoryState {
    $state = @{}
    if (-not (Test-Path $StateFile)) { return $state }

    try {
        $json = Get-Content -Path $StateFile -Raw
        if (-not $json) { return $state }
        $stored = $json | ConvertFrom-Json
        if ($stored.PSObject.Properties.Name -notcontains 'Sessions') { return $state }
        @($stored.Sessions) | ForEach-Object {
            $key = "$(Get-RowValue $_ 'SessionKey')"
            if ($key) { $state[$key] = $_ }
        }
    }
    catch {
        Write-Log "State file non leggibile ($StateFile): $($_.Exception.Message)" 'WARN'
    }

    return $state
}

function Save-SessionHistoryState {
    param([hashtable]$State)
    try {
        $parent = Split-Path -Path $StateFile -Parent
        if ($parent -and -not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
        [ordered]@{
            Version  = 1
            Updated  = $nowUtc
            Sessions = @($State.Values)
        } | ConvertTo-Json -Depth 6 | Set-Content -Path $StateFile -Encoding UTF8
    }
    catch {
        Write-Log "State file non salvato ($StateFile): $($_.Exception.Message)" 'WARN'
    }
}

function New-SessionHistoryRow {
    param(
        [string]$EventType,
        [string]$SessionKey,
        $Current,
        $Previous,
        [string]$FirstSeen,
        [string]$LastSeen
    )

    [ordered]@{
        TimeGenerated        = $nowUtc
        EventTime            = $nowUtc
        EventType            = $EventType
        SessionKey           = $SessionKey
        Computer             = "$(Get-RowValue $Current 'Computer' (Get-RowValue $Previous 'Computer'))"
        SiteName             = "$(Get-RowValue $Current 'SiteName' (Get-RowValue $Previous 'SiteName'))"
        SessionId            = [int](Get-RowValue $Current 'SessionId' (Get-RowValue $Previous 'SessionId' 0))
        UserName             = "$(Get-RowValue $Current 'UserName' (Get-RowValue $Previous 'UserName'))"
        ClientName           = "$(Get-RowValue $Current 'ClientName' (Get-RowValue $Previous 'ClientName'))"
        ClientIP             = "$(Get-RowValue $Current 'ClientIP' (Get-RowValue $Previous 'ClientIP'))"
        SessionState         = "$(Get-RowValue $Current 'SessionState' (Get-RowValue $Previous 'SessionState'))"
        PreviousSessionState = "$(Get-RowValue $Previous 'SessionState')"
        SessionType          = "$(Get-RowValue $Current 'SessionType' (Get-RowValue $Previous 'SessionType'))"
        LogonTime            = (Get-RowValue $Current 'LogonTime' (Get-RowValue $Previous 'LogonTime' $null))
        FirstSeen            = $FirstSeen
        LastSeen             = $LastSeen
        ObservedDurationSec  = (Get-DurationSeconds $FirstSeen $LastSeen)
        IdleTimeSec          = [int](Get-RowValue $Current 'IdleTimeSec' (Get-RowValue $Previous 'IdleTimeSec' 0))
        PublishedResource    = "$(Get-RowValue $Current 'PublishedResource' (Get-RowValue $Previous 'PublishedResource'))"
        Source               = 'CollectorSnapshot'
    }
}

function Get-SessionHistoryRows {
    param([object[]]$Rows)

    $previousState = Get-SessionHistoryState
    $currentState = @{}
    $historyRows = New-Object System.Collections.Generic.List[object]

    foreach ($row in @($Rows)) {
        $key = Get-SessionKey $row
        if (-not ($key -replace '\|', '')) { continue }

        $previous = if ($previousState.ContainsKey($key)) { $previousState[$key] } else { $null }
        $firstSeen = if ($previous) { "$(Get-RowValue $previous 'FirstSeen' $nowUtc)" } else { $nowUtc }
        $previousStateName = "$(Get-RowValue $previous 'SessionState')"
        $currentStateName = "$(Get-RowValue $row 'SessionState')"
        $eventType = if (-not $previous) {
            'Started'
        }
        elseif ($previousStateName -ne $currentStateName) {
            'StateChanged'
        }
        else {
            'Observed'
        }

        $historyRows.Add((New-SessionHistoryRow -EventType $eventType -SessionKey $key -Current $row -Previous $previous -FirstSeen $firstSeen -LastSeen $nowUtc))

        $currentState[$key] = [ordered]@{
            SessionKey        = $key
            Computer          = "$(Get-RowValue $row 'Computer')"
            SiteName          = "$(Get-RowValue $row 'SiteName')"
            SessionId         = [int](Get-RowValue $row 'SessionId' 0)
            UserName          = "$(Get-RowValue $row 'UserName')"
            ClientName        = "$(Get-RowValue $row 'ClientName')"
            ClientIP          = "$(Get-RowValue $row 'ClientIP')"
            SessionState      = $currentStateName
            SessionType       = "$(Get-RowValue $row 'SessionType')"
            LogonTime         = (Get-RowValue $row 'LogonTime' $null)
            FirstSeen         = $firstSeen
            LastSeen          = $nowUtc
            IdleTimeSec       = [int](Get-RowValue $row 'IdleTimeSec' 0)
            PublishedResource = "$(Get-RowValue $row 'PublishedResource')"
        }
    }

    foreach ($key in $previousState.Keys) {
        if ($currentState.ContainsKey($key)) { continue }
        $previous = $previousState[$key]
        $firstSeen = "$(Get-RowValue $previous 'FirstSeen' $nowUtc)"
        $ended = New-SessionHistoryRow -EventType 'EndedInferred' -SessionKey $key -Current $null -Previous $previous -FirstSeen $firstSeen -LastSeen $nowUtc
        $ended['SessionState'] = 'EndedInferred'
        $historyRows.Add($ended)
    }

    Save-SessionHistoryState -State $currentState
    return $historyRows.ToArray()
}

$nowUtc = (Get-Date).ToUniversalTime().ToString('o')

# ===========================================================================
#  MAIN
# ===========================================================================
try {
    Write-Log "=== Avvio raccolta RAS ==="

    if (-not $DryRun) {
        if (-not $DceLogsIngestionUri -or -not $DcrImmutableId) {
            throw "Senza -DryRun servono i parametri -DceLogsIngestionUri e -DcrImmutableId."
        }
    }
    else {
        if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
        Write-Log "DRY-RUN attivo: payload scritti in $OutDir, nessuna pubblicazione su Azure."
    }

    if (-not (Get-Module -ListAvailable -Name RASAdmin)) {
        throw "Modulo PowerShell 'RASAdmin' (RAS 20/21) non installato su questo host."
    }
    Import-Module RASAdmin -ErrorAction Stop

    # Credenziali RAS: -RasCredential ha precedenza su Key Vault
    if ($RasCredential) {
        Write-Log "Uso credenziali RAS fornite via -RasCredential."
        $rasUser = $RasCredential.UserName
        $secPass = $RasCredential.Password
    }
    else {
        if (-not $KeyVaultName) { throw "Specificare -KeyVaultName oppure -RasCredential." }
        Write-Log "Lettura credenziali RAS da Key Vault '$KeyVaultName'..."
        $rasUser = Get-KeyVaultSecretValue -VaultName $KeyVaultName -SecretName $RasUserSecretName
        $rasPass = Get-KeyVaultSecretValue -VaultName $KeyVaultName -SecretName $RasPasswordSecretName
        $secPass = ConvertTo-SecureString $rasPass -AsPlainText -Force
    }

    Write-Log "Connessione alla farm RAS ($RasServer)..."
    New-RASSession -Server $RasServer -Username $rasUser -Password $secPass | Out-Null

    $monitorToken = if ($DryRun) { '' } else { Get-MsiAccessToken -Resource $ResourceMonitor }

    # Mappa SiteId -> Name
    $siteMap = @{}
    try { Get-RASSite | ForEach-Object { $siteMap["$(Get-Prop $_ @('Id'))"] = "$(Get-Prop $_ @('Name'))" } } catch { Write-Log "Get-RASSite: $($_.Exception.Message)" 'WARN' }
    function Resolve-Site { param($SiteId) $k = "$SiteId"; if ($siteMap.ContainsKey($k)) { $siteMap[$k] } else { $k } }

    # Mappa IP/Server -> Nome provider (es. 10.10.200.26 -> VMware Lab)
    $providerMap = @{}
    try { Get-RASProvider | ForEach-Object { $providerMap["$(Get-Prop $_ @('Server','IP','Address'))"] = "$(Get-Prop $_ @('Name','Description'))" } } catch { Write-Log "Get-RASProvider: $($_.Exception.Message)" 'WARN' }

    # Tipi logici senza agente fisico: esclusi da RASServer_CL e RASAgent_CL
    $logicalTypes = @('Site','RDSGroup','VDITemplate','VDIHostPool')

    # -----------------------------------------------------------------------
    #  Get-RASAgent -> RASServer_CL + RASAgent_CL  (fonte unica per inventario+versioni)
    # -----------------------------------------------------------------------
    $serverRows = New-Object System.Collections.Generic.List[object]
    $agentRows  = New-Object System.Collections.Generic.List[object]
    try {
        Get-RASAgent | ForEach-Object {
            $rawType = "$(Get-Prop $_ @('ServerType','Type') '')"
            if ($logicalTypes -contains $rawType) { return }   # oggetto logico RAS, nessun agente fisico
            $srv  = Get-Prop $_ @('Server','Name')
            $role = Resolve-Role $rawType
            # Per i Provider risolvi IP -> nome friendly se disponibile
            if ($role -eq 'Provider' -and $providerMap.ContainsKey("$srv")) { $srv = $providerMap["$srv"] }
            $site = Resolve-Site (Get-Prop $_ @('SiteId'))
            # Provider: nome friendly o IP, non normalizzare come hostname (no FQDN suffix)
            $comp = if ($role -eq 'Provider') { $srv.ToLower() } else { Resolve-ComputerName $srv }

            $serverRows.Add([ordered]@{
                TimeGenerated = $nowUtc
                Computer      = $comp
                FarmName      = $FarmName
                SiteName      = $site
                Role          = $role
                ServerStatus  = "$(Get-Prop $_ @('AgentState','State') 'Unknown')"
                AgentVersion  = "$(Get-Prop $_ @('AgentVer','AgentVersion','Version') '')"
                OSVersion     = "$(Get-Prop $_ @('ServerOS','OSVersion','OS') '')"
                IPAddress     = "$(Get-Prop $_ @('IP','IPAddress','DirectAddress') '')"
                Enabled       = [bool](Get-Prop $_ @('Enabled') $true)
            })
            $agentVer = "$(Get-Prop $_ @('AgentVer','AgentVersion','Version') '')"
            if ($agentVer) {
                $agentRows.Add([ordered]@{
                    TimeGenerated = $nowUtc
                    Computer      = $comp
                    SiteName      = $site
                    AgentType     = $rawType
                    AgentState    = "$(Get-Prop $_ @('AgentState','State') '')"
                    AgentVersion  = $agentVer
                    OSVersion     = "$(Get-Prop $_ @('ServerOS','OSVersion','OS') '')"
                })
            }
        }
    } catch { Write-Log "Get-RASAgent: $($_.Exception.Message)" 'WARN' }
    Send-LogStream -Stream (Get-StreamName $Tables.Server) -Rows $serverRows.ToArray() -MonitorToken $monitorToken
    Send-LogStream -Stream (Get-StreamName $Tables.Agent)  -Rows $agentRows.ToArray()  -MonitorToken $monitorToken

    # -----------------------------------------------------------------------
    #  Get-RASRDSession -Source All -> RASSession_CL
    # -----------------------------------------------------------------------
    $sessionRows = New-Object System.Collections.Generic.List[object]
    try {
        Get-RASRDSession -Source All | ForEach-Object {
            $sessionRows.Add([ordered]@{
                TimeGenerated     = $nowUtc
                Computer          = Resolve-ComputerName (Get-Prop $_ @('SessionHostName','ServerName','HostName'))
                SiteName          = ''   # RDSession non espone il sito
                SessionId         = [int](Get-Prop $_ @('SessionID','SessionId','Id') 0)
                UserName          = "$(Get-Prop $_ @('User','UserName') '')"
                ClientName        = "$(Get-Prop $_ @('DeviceName','ClientName') '')"
                ClientIP          = "$(Get-Prop $_ @('ClientIPAddress','ClientIP','IP') '')"
                SessionState      = "$(Get-Prop $_ @('State','SessionState') '')"
                SessionType       = "$(Get-Prop $_ @('Source','SessionType') 'RDS')"
                LogonTime         = ConvertTo-IsoUtc (Get-Prop $_ @('LogonTime'))
                IdleTimeSec       = [int](Get-Prop $_ @('IdleTime','IdleSeconds') 0)
                PublishedResource = "$(Get-Prop $_ @('PoolName','TemplateName','PublishedName') '')"
            })
        }
    } catch { Write-Log "Get-RASRDSession: $($_.Exception.Message)" 'WARN' }
    Send-LogStream -Stream (Get-StreamName $Tables.Session) -Rows $sessionRows.ToArray() -MonitorToken $monitorToken

    $sessionHistoryRows = @()
    try {
        $sessionHistoryRows = Get-SessionHistoryRows -Rows $sessionRows.ToArray()
    }
    catch {
        Write-Log "RASSessionHistory_CL: $($_.Exception.Message)" 'WARN'
    }
    Send-LogStream -Stream (Get-StreamName $Tables.SessionHistory) -Rows @($sessionHistoryRows) -MonitorToken $monitorToken

    # -----------------------------------------------------------------------
    #  Audit (best-effort): sessioni admin alla console RAS.
    #  Note: detailed configuration-change audit is not fully exposed via
    #      PowerShell in modo completo (vedi README). Get-RASNotificationEvent
    #      restituisce le REGOLE di notifica (config), non eventi: NON usato.
    #  AdminSession espone UserId -> risolto a nome via Get-RASAdminAccount.
    # -----------------------------------------------------------------------
    $adminMap = @{}
    try { Get-RASAdminAccount | ForEach-Object { $adminMap["$(Get-Prop $_ @('Id'))"] = "$(Get-Prop $_ @('Name','Account','UserName','Email') '')" } } catch { Write-Log "Get-RASAdminAccount: $($_.Exception.Message)" 'WARN' }

    $auditRows = New-Object System.Collections.Generic.List[object]
    try {
        Get-RASAdminSession | ForEach-Object {
            $adminLogon = ConvertTo-IsoUtc (Get-Prop $_ @('LogonTime'))
            if (-not $adminLogon) { $adminLogon = $nowUtc }
            $uid = "$(Get-Prop $_ @('UserId','AdminId') '')"
            $aname = if ($uid -and $adminMap.ContainsKey($uid) -and $adminMap[$uid]) { $adminMap[$uid] } else { "$(Get-Prop $_ @('ComputerName') '')" }
            $auditRows.Add([ordered]@{
                TimeGenerated = $adminLogon
                SiteName      = ''
                AdminUser     = $aname
                Action        = 'AdminConsoleSession'
                ObjectType    = 'AdminSession'
                ObjectName    = "$(Get-Prop $_ @('ComputerName') '')"
                Result        = "$(Get-Prop $_ @('State') '')"
                ClientIP      = "$(Get-Prop $_ @('IP') '')"
                Source        = 'AdminSession'
            })
        }
    } catch { Write-Log "Get-RASAdminSession: $($_.Exception.Message)" 'WARN' }
    Send-LogStream -Stream (Get-StreamName $Tables.Audit) -Rows $auditRows.ToArray() -MonitorToken $monitorToken

    Write-Log "=== Completato: server=$($serverRows.Count) agent=$($agentRows.Count) session=$($sessionRows.Count) sessionHistory=$(@($sessionHistoryRows).Count) audit=$($auditRows.Count) ==="
}
catch {
    Write-Log $_.Exception.Message 'ERROR'
    throw
}
finally {
    try { Remove-RASSession -ErrorAction SilentlyContinue } catch {}
}
