<#
.SYNOPSIS
    Executes rollback operations for SAP BusinessObjects deployments.

.DESCRIPTION
    Restores BOBJ content from a backup LCMBIAR file when a deployment fails.
    Uses the Import-BOBJContent.ps1 script with LCMCLI under the hood.

.PARAMETER CmsServer
    The CMS server hostname

.PARAMETER Username
    Username for BOBJ authentication

.PARAMETER Password
    Password for BOBJ authentication

.PARAMETER BackupPath
    Path to the backup LCMBIAR file or directory

.PARAMETER LcmcliPath
    Path to the lcmcli.bat tool on the BOBJ server

.PARAMETER VerboseLogging
    Enable verbose logging
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$CmsServer,
    
    [Parameter(Mandatory = $true)]
    [string]$Username,
    
    [Parameter(Mandatory = $true)]
    [string]$Password,
    
    [Parameter(Mandatory = $true)]
    [string]$BackupPath,
    
    [Parameter(Mandatory = $false)]
    [string]$LcmcliPath = 'C:\Program Files (x86)\SAP BusinessObjects\SAP BusinessObjects Enterprise XI 4.0\win64_x64\scripts\lcm\lcmcli.bat',
    
    [Parameter(Mandatory = $false)]
    [switch]$VerboseLogging = $false,

    # Legacy parameter - kept for backward compatibility
    [Parameter(Mandatory = $false)]
    [string]$ServerUrl
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
    Write-Log "CMS Server: $CmsServer"
    Write-Log "Backup Path: $BackupPath"
    
    if ($ServerUrl) {
        Write-Log "NOTE: -ServerUrl parameter is deprecated. LCMCLI connects directly via CMS. Ignoring ServerUrl." -Level WARN
    }
    
    # Verify backup exists
    if (-not (Test-Path $BackupPath)) {
        Write-Log "Backup not found at: $BackupPath" -Level ERROR
        exit 1
    }
    
    Write-Log "Backup verified, initiating restore..."
    
    # Call Import-BOBJContent with rollback settings
    $importScript = Join-Path $PSScriptRoot "Import-BOBJContent.ps1"
    
    $params = @{
        CmsServer = $CmsServer
        Username = $Username
        Password = $Password
        LcmbiarPath = $BackupPath
        ConflictResolution = 'UpdateExisting'
        OverwriteSecurity = $true
        LcmcliPath = $LcmcliPath
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
