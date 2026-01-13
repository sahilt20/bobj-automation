<#
.SYNOPSIS
    Exports SAP BusinessObjects content to LCMBIAR archive.

.DESCRIPTION
    This script connects to a SAP BusinessObjects system and exports content
    (reports, universes, connections, folders) to an LCMBIAR file for transport.

.PARAMETER ServerUrl
    The URL of the BOBJ server (e.g., http://bobj-server:8080)

.PARAMETER CmsServer
    The CMS server hostname or IP address

.PARAMETER CmsPort
    The CMS server port (default: 6400)

.PARAMETER Username
    Username for BOBJ authentication

.PARAMETER Password
    Password for BOBJ authentication

.PARAMETER AuthType
    Authentication type (secEnterprise, secLDAP, secWinAD, secSAPR3)

.PARAMETER ExportFolder
    The folder path in BOBJ to export (e.g., /Public Folders/Reports)

.PARAMETER OutputPath
    Path where the LCMBIAR file will be saved

.PARAMETER IncludeSecurityRights
    Include security rights in the export

.PARAMETER IncludeDependencies
    Include dependent objects in the export

.PARAMETER BackupMode
    Run in backup mode (exports all content for recovery purposes)

.PARAMETER VerboseLogging
    Enable verbose logging

.EXAMPLE
    .\Export-BOBJContent.ps1 -ServerUrl "http://bobj:8080" -CmsServer "bobj-cms" -Username "admin" -Password "pass" -ExportFolder "/Public Folders" -OutputPath "./export"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ServerUrl,
    
    [Parameter(Mandatory = $true)]
    [string]$CmsServer,
    
    [Parameter(Mandatory = $false)]
    [int]$CmsPort = 6400,
    
    [Parameter(Mandatory = $true)]
    [string]$Username,
    
    [Parameter(Mandatory = $true)]
    [string]$Password,
    
    [Parameter(Mandatory = $false)]
    [ValidateSet('secEnterprise', 'secLDAP', 'secWinAD', 'secSAPR3')]
    [string]$AuthType = 'secEnterprise',
    
    [Parameter(Mandatory = $false)]
    [string]$ExportFolder = '/Public Folders',
    
    [Parameter(Mandatory = $true)]
    [string]$OutputPath,
    
    [Parameter(Mandatory = $false)]
    [switch]$IncludeSecurityRights = $true,
    
    [Parameter(Mandatory = $false)]
    [switch]$IncludeDependencies = $true,
    
    [Parameter(Mandatory = $false)]
    [switch]$BackupMode = $false,
    
    [Parameter(Mandatory = $false)]
    [switch]$VerboseLogging = $false
)

# Set error action preference
$ErrorActionPreference = 'Stop'

# Import logging functions
function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'DEBUG')]
        [string]$Level = 'INFO'
    )
    
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $logMessage = "[$timestamp] [$Level] $Message"
    
    switch ($Level) {
        'ERROR' { Write-Host $logMessage -ForegroundColor Red }
        'WARN'  { Write-Host $logMessage -ForegroundColor Yellow }
        'DEBUG' { if ($VerboseLogging) { Write-Host $logMessage -ForegroundColor Gray } }
        default { Write-Host $logMessage }
    }
}

function Get-BOBJSession {
    param(
        [string]$ServerUrl,
        [string]$Username,
        [string]$Password,
        [string]$AuthType
    )
    
    Write-Log "Authenticating to BOBJ server: $ServerUrl" -Level INFO
    
    $loginUrl = "$ServerUrl/biprws/logon/long"
    
    $loginBody = @{
        userName = $Username
        password = $Password
        auth = $AuthType
    } | ConvertTo-Json
    
    try {
        $response = Invoke-RestMethod -Uri $loginUrl -Method Post -Body $loginBody -ContentType 'application/json'
        $logonToken = $response.logonToken
        
        if (-not $logonToken) {
            throw "Failed to obtain logon token"
        }
        
        Write-Log "Successfully authenticated to BOBJ" -Level INFO
        return $logonToken
    }
    catch {
        Write-Log "Authentication failed: $_" -Level ERROR
        throw
    }
}

function Get-FolderContents {
    param(
        [string]$ServerUrl,
        [string]$LogonToken,
        [string]$FolderPath
    )
    
    Write-Log "Fetching contents of folder: $FolderPath" -Level DEBUG
    
    $headers = @{
        'X-SAP-LogonToken' = $LogonToken
        'Accept' = 'application/json'
    }
    
    # Get folder ID from path
    $encodedPath = [System.Web.HttpUtility]::UrlEncode($FolderPath)
    $folderUrl = "$ServerUrl/biprws/infostore/folder?path=$encodedPath"
    
    try {
        $folderInfo = Invoke-RestMethod -Uri $folderUrl -Method Get -Headers $headers
        return $folderInfo
    }
    catch {
        Write-Log "Failed to get folder contents: $_" -Level WARN
        return $null
    }
}

function Export-ToLCMBIAR {
    param(
        [string]$ServerUrl,
        [string]$LogonToken,
        [string]$FolderPath,
        [string]$OutputPath,
        [bool]$IncludeSecurity,
        [bool]$IncludeDeps
    )
    
    Write-Log "Starting LCMBIAR export from: $FolderPath" -Level INFO
    
    $headers = @{
        'X-SAP-LogonToken' = $LogonToken
        'Accept' = 'application/json'
        'Content-Type' = 'application/json'
    }
    
    # Create promotion job
    $promotionJob = @{
        name = "Export_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
        sourcePath = $FolderPath
        includeSecurityRights = $IncludeSecurity
        includeDependencies = $IncludeDeps
        exportType = "LCMBIAR"
    }
    
    $promotionUrl = "$ServerUrl/biprws/lcm/promotions"
    
    try {
        Write-Log "Creating promotion job..." -Level DEBUG
        $jobResponse = Invoke-RestMethod -Uri $promotionUrl -Method Post -Headers $headers -Body ($promotionJob | ConvertTo-Json)
        
        $jobId = $jobResponse.id
        Write-Log "Promotion job created with ID: $jobId" -Level INFO
        
        # Wait for job completion
        $maxAttempts = 60
        $attempts = 0
        $completed = $false
        
        while (-not $completed -and $attempts -lt $maxAttempts) {
            Start-Sleep -Seconds 5
            $attempts++
            
            $statusUrl = "$ServerUrl/biprws/lcm/promotions/$jobId/status"
            $status = Invoke-RestMethod -Uri $statusUrl -Method Get -Headers $headers
            
            Write-Log "Job status: $($status.state) (attempt $attempts/$maxAttempts)" -Level DEBUG
            
            if ($status.state -eq 'Completed') {
                $completed = $true
            }
            elseif ($status.state -eq 'Failed') {
                throw "Promotion job failed: $($status.errorMessage)"
            }
        }
        
        if (-not $completed) {
            throw "Promotion job timed out after $maxAttempts attempts"
        }
        
        # Download LCMBIAR file
        Write-Log "Downloading LCMBIAR file..." -Level INFO
        
        $downloadUrl = "$ServerUrl/biprws/lcm/promotions/$jobId/download"
        $lcmbiarFile = Join-Path $OutputPath "export_$(Get-Date -Format 'yyyyMMdd_HHmmss').lcmbiar"
        
        # Ensure output directory exists
        if (-not (Test-Path $OutputPath)) {
            New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
        }
        
        Invoke-WebRequest -Uri $downloadUrl -Method Get -Headers $headers -OutFile $lcmbiarFile
        
        Write-Log "LCMBIAR file saved to: $lcmbiarFile" -Level INFO
        
        return @{
            Success = $true
            FilePath = $lcmbiarFile
            JobId = $jobId
        }
    }
    catch {
        Write-Log "Export failed: $_" -Level ERROR
        return @{
            Success = $false
            Error = $_.Exception.Message
        }
    }
}

function Close-BOBJSession {
    param(
        [string]$ServerUrl,
        [string]$LogonToken
    )
    
    Write-Log "Closing BOBJ session..." -Level DEBUG
    
    $logoffUrl = "$ServerUrl/biprws/logoff"
    $headers = @{
        'X-SAP-LogonToken' = $LogonToken
    }
    
    try {
        Invoke-RestMethod -Uri $logoffUrl -Method Post -Headers $headers | Out-Null
        Write-Log "Session closed successfully" -Level DEBUG
    }
    catch {
        Write-Log "Failed to close session cleanly: $_" -Level WARN
    }
}

# Main execution
try {
    Write-Log "=== BOBJ Content Export Started ===" -Level INFO
    Write-Log "Server URL: $ServerUrl" -Level INFO
    Write-Log "Export Folder: $ExportFolder" -Level INFO
    Write-Log "Output Path: $OutputPath" -Level INFO
    Write-Log "Include Security: $IncludeSecurityRights" -Level INFO
    Write-Log "Include Dependencies: $IncludeDependencies" -Level INFO
    Write-Log "Backup Mode: $BackupMode" -Level INFO
    
    # Add System.Web for URL encoding
    Add-Type -AssemblyName System.Web
    
    # Authenticate
    $logonToken = Get-BOBJSession -ServerUrl $ServerUrl -Username $Username -Password $Password -AuthType $AuthType
    
    # Export content
    $exportResult = Export-ToLCMBIAR `
        -ServerUrl $ServerUrl `
        -LogonToken $logonToken `
        -FolderPath $ExportFolder `
        -OutputPath $OutputPath `
        -IncludeSecurity $IncludeSecurityRights `
        -IncludeDeps $IncludeDependencies
    
    # Close session
    Close-BOBJSession -ServerUrl $ServerUrl -LogonToken $logonToken
    
    if ($exportResult.Success) {
        Write-Log "=== Export Completed Successfully ===" -Level INFO
        Write-Log "LCMBIAR file: $($exportResult.FilePath)" -Level INFO
        
        # Output for Azure DevOps
        Write-Host "##vso[task.setvariable variable=lcmbiarPath]$($exportResult.FilePath)"
        Write-Host "##vso[task.setvariable variable=exportJobId]$($exportResult.JobId)"
        
        exit 0
    }
    else {
        Write-Log "=== Export Failed ===" -Level ERROR
        Write-Log "Error: $($exportResult.Error)" -Level ERROR
        exit 1
    }
}
catch {
    Write-Log "Unhandled error: $_" -Level ERROR
    Write-Log $_.ScriptStackTrace -Level ERROR
    exit 1
}
