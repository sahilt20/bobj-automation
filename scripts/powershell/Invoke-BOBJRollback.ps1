<#
.SYNOPSIS
    Executes rollback of SAP BusinessObjects deployment via Raylight REST API.

.DESCRIPTION
    Restores BOBJ content from a backup LCMBIAR file using the Promotion
    Management API (/biprws/promotion/) with overwrite conflict resolution.

.PARAMETER ServerUrl
    Base URL of the BOBJ server

.PARAMETER CmsServer
    CMS server hostname

.PARAMETER Username
    BOBJ service account username

.PARAMETER Password
    BOBJ service account password

.PARAMETER AuthType
    Authentication type (default: secEnterprise)

.PARAMETER BackupPath
    Path to backup LCMBIAR file or directory

.PARAMETER JobTimeoutSeconds
    Max wait for rollback import (default 1800)

.PARAMETER VerboseLogging
    Enable debug logging
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$ServerUrl,
    [Parameter(Mandatory=$true)][string]$CmsServer,
    [Parameter(Mandatory=$true)][string]$Username,
    [Parameter(Mandatory=$true)][string]$Password,
    [Parameter(Mandatory=$false)][ValidateSet('secEnterprise','secLDAP','secWinAD','secSAPR3')][string]$AuthType = 'secEnterprise',
    [Parameter(Mandatory=$true)][string]$BackupPath,
    [Parameter(Mandatory=$false)][int]$JobTimeoutSeconds = 1800,
    [Parameter(Mandatory=$false)][switch]$VerboseLogging
)

$ErrorActionPreference = 'Stop'

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    switch ($Level) {
        'ERROR' { Write-Host "[$ts] [$Level] $Message" -ForegroundColor Red }
        'WARN'  { Write-Host "[$ts] [$Level] $Message" -ForegroundColor Yellow }
        'OK'    { Write-Host "[$ts] [$Level] $Message" -ForegroundColor Green }
        default { Write-Host "[$ts] [$Level] $Message" }
    }
}

try {
    Write-Log "================================================================" -Level WARN
    Write-Log "  BOBJ ROLLBACK via Raylight REST API" -Level WARN
    Write-Log "================================================================"
    Write-Log "Server: $ServerUrl | CMS: $CmsServer | Backup: $BackupPath"

    # Verify backup
    if (-not (Test-Path $BackupPath)) {
        Write-Log "Backup not found: $BackupPath" -Level ERROR
        Write-Host "##vso[task.logissue type=error]Rollback backup not found"
        Write-Host "##vso[task.setvariable variable=rollbackStatus]failed"
        exit 1
    }

    if (Test-Path $BackupPath -PathType Container) {
        $backupSize = (Get-ChildItem -Path $BackupPath -Recurse -File | Measure-Object -Property Length -Sum).Sum
    } else {
        $backupSize = (Get-Item $BackupPath).Length
    }
    Write-Log "Backup verified: $([math]::Round($backupSize / 1MB, 2)) MB"

    # Execute rollback via Import-BOBJContent.ps1
    $importScript = Join-Path $PSScriptRoot "Import-BOBJContent.ps1"
    if (-not (Test-Path $importScript)) { throw "Import-BOBJContent.ps1 not found at $importScript" }

    Write-Log "Restoring from backup via Raylight Promotion API..."

    $params = @{
        ServerUrl          = $ServerUrl
        CmsServer          = $CmsServer
        Username           = $Username
        Password           = $Password
        AuthType           = $AuthType
        LcmbiarPath        = $BackupPath
        ConflictResolution = 'UpdateExisting'
        OverwriteSecurity  = $true
        JobTimeoutSeconds  = $JobTimeoutSeconds
    }
    if ($VerboseLogging) { $params.Add('VerboseLogging', $true) }

    & $importScript @params
    $exitCode = $LASTEXITCODE

    if ($exitCode -eq 0) {
        Write-Log "================================================================"
        Write-Log "  Rollback Completed Successfully" -Level OK
        Write-Log "================================================================"
        Write-Host "##vso[task.setvariable variable=rollbackStatus]success"
        exit 0
    }
    else {
        Write-Log "================================================================"
        Write-Log "  Rollback Failed (exit code: $exitCode)" -Level ERROR
        Write-Log "================================================================"
        Write-Host "##vso[task.logissue type=error]Rollback failed"
        Write-Host "##vso[task.setvariable variable=rollbackStatus]failed"
        exit 1
    }
}
catch {
    Write-Log "Rollback error: $_" -Level ERROR
    Write-Log $_.ScriptStackTrace -Level ERROR
    Write-Host "##vso[task.logissue type=error]Rollback error: $_"
    Write-Host "##vso[task.setvariable variable=rollbackStatus]error"
    exit 1
}
