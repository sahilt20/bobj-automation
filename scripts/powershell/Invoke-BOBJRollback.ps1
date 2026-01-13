<#
.SYNOPSIS
    Executes rollback operations for SAP BusinessObjects deployments.

.DESCRIPTION
    Restores BOBJ content from a backup LCMBIAR file when a deployment fails.

.PARAMETER ServerUrl
    The URL of the BOBJ server

.PARAMETER CmsServer
    The CMS server hostname

.PARAMETER Username
    Username for BOBJ authentication

.PARAMETER Password
    Password for BOBJ authentication

.PARAMETER BackupPath
    Path to the backup LCMBIAR file or directory

.PARAMETER VerboseLogging
    Enable verbose logging
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ServerUrl,
    
    [Parameter(Mandatory = $true)]
    [string]$CmsServer,
    
    [Parameter(Mandatory = $true)]
    [string]$Username,
    
    [Parameter(Mandatory = $true)]
    [string]$Password,
    
    [Parameter(Mandatory = $true)]
    [string]$BackupPath,
    
    [Parameter(Mandatory = $false)]
    [switch]$VerboseLogging = $false
)

$ErrorActionPreference = 'Stop'

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    switch ($Level) {
        'ERROR' { Write-Host "[$timestamp] [$Level] $Message" -ForegroundColor Red }
        'WARN'  { Write-Host "[$timestamp] [$Level] $Message" -ForegroundColor Yellow }
        'OK'    { Write-Host "[$timestamp] [$Level] $Message" -ForegroundColor Green }
        default { Write-Host "[$timestamp] [$Level] $Message" }
    }
}

try {
    Write-Log "=== BOBJ Rollback Started ===" -Level WARN
    Write-Log "Server URL: $ServerUrl"
    Write-Log "Backup Path: $BackupPath"
    
    # Verify backup exists
    if (-not (Test-Path $BackupPath)) {
        Write-Log "Backup not found at: $BackupPath" -Level ERROR
        exit 1
    }
    
    Write-Log "Backup verified, initiating restore..."
    
    # Call Import-BOBJContent with rollback flag
    $importScript = Join-Path $PSScriptRoot "Import-BOBJContent.ps1"
    
    $params = @{
        ServerUrl = $ServerUrl
        CmsServer = $CmsServer
        Username = $Username
        Password = $Password
        LcmbiarPath = $BackupPath
        ConflictResolution = 'UpdateExisting'
        OverwriteSecurity = $true
    }
    
    if ($VerboseLogging) {
        $params.Add('VerboseLogging', $true)
    }
    
    Write-Log "Executing restore from backup..."
    
    & $importScript @params
    
    $exitCode = $LASTEXITCODE
    
    if ($exitCode -eq 0) {
        Write-Log "=== Rollback Completed Successfully ===" -Level OK
        
        # Set Azure DevOps variable
        Write-Host "##vso[task.setvariable variable=rollbackStatus]success"
        
        exit 0
    }
    else {
        Write-Log "=== Rollback Failed ===" -Level ERROR
        Write-Host "##vso[task.setvariable variable=rollbackStatus]failed"
        exit 1
    }
}
catch {
    Write-Log "Rollback error: $_" -Level ERROR
    Write-Host "##vso[task.setvariable variable=rollbackStatus]error"
    exit 1
}
