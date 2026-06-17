<#
.SYNOPSIS
    Registra lo scheduled task che esegue Collect-RasInventory.ps1 ogni 5 minuti.

.DESCRIPTION
    Esegue il collector come SYSTEM (account con accesso alla Managed Identity Arc/IMDS
    e privilegi per leggere il challenge token Arc). Da lanciare in PowerShell elevato
    sull'host RAS designato (Connection Broker / RAS Console).

.EXAMPLE
    .\Install-RasCollectorTask.ps1 `
        -DceLogsIngestionUri "https://ras-dce-xxxx.westeurope-1.ingest.monitor.azure.com" `
        -DcrImmutableId "dcr-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" `
        -KeyVaultName "kv-ras-prod"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $DceLogsIngestionUri,
    [Parameter(Mandatory)] [string] $DcrImmutableId,
    [Parameter(Mandatory)] [string] $KeyVaultName,

    [string] $RasServer = 'localhost',
    [string] $FarmName = '',
    [string] $ComputerNameStyle = 'AsIs',
    [string] $DnsDomain = '',
    [int]    $IntervalMinutes = 5,
    [string] $TaskName = 'Parallels RAS - Azure Monitor Collector',
    [string] $ScriptPath = "$PSScriptRoot\Collect-RasInventory.ps1"
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $ScriptPath)) { throw "Script non trovato: $ScriptPath" }

# Argomenti passati allo script di raccolta
$argLine = @(
    '-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$ScriptPath`"",
    '-DceLogsIngestionUri',"`"$DceLogsIngestionUri`"",
    '-DcrImmutableId',"`"$DcrImmutableId`"",
    '-KeyVaultName',"`"$KeyVaultName`"",
    '-RasServer',"`"$RasServer`"",
    '-ComputerNameStyle',"`"$ComputerNameStyle`""
)
if ($FarmName)  { $argLine += @('-FarmName',"`"$FarmName`"") }
if ($DnsDomain) { $argLine += @('-DnsDomain',"`"$DnsDomain`"") }

$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ($argLine -join ' ')

# Trigger: ripetizione ogni N minuti per 1 giorno, rinnovato (pattern classico per <24h)
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).Date.AddMinutes(1) `
    -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes)

$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 4) `
    -MultipleInstances IgnoreNew

if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Write-Host "Aggiorno il task esistente '$TaskName'..."
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
}

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
    -Principal $principal -Settings $settings `
    -Description 'Raccoglie dati Parallels RAS e li pubblica su Azure Monitor Logs (Logs Ingestion API).' | Out-Null

Write-Host "Task '$TaskName' registrato: esecuzione ogni $IntervalMinutes minuti come SYSTEM."
Write-Host "Avvio una prima esecuzione di prova..."
Start-ScheduledTask -TaskName $TaskName
Write-Host "Fatto. Log: $PSScriptRoot\Collect-RasInventory.log"
