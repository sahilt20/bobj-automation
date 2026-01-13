<#
.SYNOPSIS
    Imports LCMBIAR content to SAP BusinessObjects system.

.DESCRIPTION
    This script connects to a SAP BusinessObjects system and imports content
    from an LCMBIAR archive file.

.PARAMETER ServerUrl
    The URL of the BOBJ server

.PARAMETER CmsServer
    The CMS server hostname

.PARAMETER Username
    Username for BOBJ authentication

.PARAMETER Password
    Password for BOBJ authentication

.PARAMETER LcmbiarPath
    Path to the LCMBIAR file or directory containing LCMBIAR files

.PARAMETER ConflictResolution
    How to handle conflicts (UpdateExisting, SkipExisting, RenameNew, Fail)

.PARAMETER OverwriteSecurity
    Overwrite security settings during import

.PARAMETER VerboseLogging
    Enable verbose logging
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
    
    [Parameter(Mandatory = $true)]
    [string]$LcmbiarPath,
    
    [Parameter(Mandatory = $false)]
    [ValidateSet('UpdateExisting', 'SkipExisting', 'RenameNew', 'Fail')]
    [string]$ConflictResolution = 'UpdateExisting',
    
    [Parameter(Mandatory = $false)]
    [switch]$OverwriteSecurity = $false,
    
    [Parameter(Mandatory = $false)]
    [switch]$VerboseLogging = $false
)

$ErrorActionPreference = 'Stop'

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
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
    param([string]$ServerUrl, [string]$Username, [string]$Password, [string]$AuthType)
    
    Write-Log "Authenticating to BOBJ server: $ServerUrl"
    
    $loginUrl = "$ServerUrl/biprws/logon/long"
    $loginBody = @{
        userName = $Username
        password = $Password
        auth = $AuthType
    } | ConvertTo-Json
    
    try {
        $response = Invoke-RestMethod -Uri $loginUrl -Method Post -Body $loginBody -ContentType 'application/json'
        $logonToken = $response.logonToken
        
        if (-not $logonToken) { throw "Failed to obtain logon token" }
        
        Write-Log "Successfully authenticated"
        return $logonToken
    }
    catch {
        Write-Log "Authentication failed: $_" -Level ERROR
        throw
    }
}

function Import-FromLCMBIAR {
    param(
        [string]$ServerUrl,
        [string]$LogonToken,
        [string]$LcmbiarFile,
        [string]$ConflictResolution,
        [bool]$OverwriteSecurity
    )
    
    Write-Log "Starting LCMBIAR import: $LcmbiarFile"
    
    $headers = @{
        'X-SAP-LogonToken' = $LogonToken
        'Accept' = 'application/json'
    }
    
    # Map conflict resolution to API values
    $conflictMap = @{
        'UpdateExisting' = 'overwrite'
        'SkipExisting' = 'skip'
        'RenameNew' = 'rename'
        'Fail' = 'fail'
    }
    
    try {
        # Upload LCMBIAR file
        Write-Log "Uploading LCMBIAR file..." -Level DEBUG
        
        $uploadUrl = "$ServerUrl/biprws/lcm/imports"
        $fileBytes = [System.IO.File]::ReadAllBytes($LcmbiarFile)
        $fileName = [System.IO.Path]::GetFileName($LcmbiarFile)
        
        $boundary = [System.Guid]::NewGuid().ToString()
        $headers['Content-Type'] = "multipart/form-data; boundary=$boundary"
        
        # Build multipart form data
        $bodyLines = @(
            "--$boundary",
            "Content-Disposition: form-data; name=`"file`"; filename=`"$fileName`"",
            "Content-Type: application/octet-stream",
            "",
            [System.Text.Encoding]::UTF8.GetString($fileBytes),
            "--$boundary",
            "Content-Disposition: form-data; name=`"conflictResolution`"",
            "",
            $conflictMap[$ConflictResolution],
            "--$boundary",
            "Content-Disposition: form-data; name=`"overwriteSecurity`"",
            "",
            $OverwriteSecurity.ToString().ToLower(),
            "--$boundary--"
        )
        
        $uploadResponse = Invoke-RestMethod -Uri $uploadUrl -Method Post -Headers $headers -Body ($bodyLines -join "`r`n")
        
        $importJobId = $uploadResponse.id
        Write-Log "Import job created with ID: $importJobId"
        
        # Wait for import completion
        $maxAttempts = 120
        $attempts = 0
        $completed = $false
        
        while (-not $completed -and $attempts -lt $maxAttempts) {
            Start-Sleep -Seconds 5
            $attempts++
            
            $statusUrl = "$ServerUrl/biprws/lcm/imports/$importJobId/status"
            $statusHeaders = @{
                'X-SAP-LogonToken' = $LogonToken
                'Accept' = 'application/json'
            }
            $status = Invoke-RestMethod -Uri $statusUrl -Method Get -Headers $statusHeaders
            
            Write-Log "Import status: $($status.state) (attempt $attempts/$maxAttempts)" -Level DEBUG
            
            if ($status.state -eq 'Completed') {
                $completed = $true
            }
            elseif ($status.state -eq 'Failed') {
                throw "Import job failed: $($status.errorMessage)"
            }
        }
        
        if (-not $completed) {
            throw "Import job timed out"
        }
        
        # Get import results
        $resultsUrl = "$ServerUrl/biprws/lcm/imports/$importJobId/results"
        $results = Invoke-RestMethod -Uri $resultsUrl -Method Get -Headers $statusHeaders
        
        Write-Log "Import completed successfully"
        Write-Log "Objects imported: $($results.importedCount)" -Level INFO
        Write-Log "Objects skipped: $($results.skippedCount)" -Level INFO
        Write-Log "Objects failed: $($results.failedCount)" -Level INFO
        
        return @{
            Success = $true
            JobId = $importJobId
            ImportedCount = $results.importedCount
            SkippedCount = $results.skippedCount
            FailedCount = $results.failedCount
        }
    }
    catch {
        Write-Log "Import failed: $_" -Level ERROR
        return @{
            Success = $false
            Error = $_.Exception.Message
        }
    }
}

function Close-BOBJSession {
    param([string]$ServerUrl, [string]$LogonToken)
    
    $logoffUrl = "$ServerUrl/biprws/logoff"
    $headers = @{ 'X-SAP-LogonToken' = $LogonToken }
    
    try {
        Invoke-RestMethod -Uri $logoffUrl -Method Post -Headers $headers | Out-Null
        Write-Log "Session closed" -Level DEBUG
    }
    catch {
        Write-Log "Failed to close session: $_" -Level WARN
    }
}

# Main execution
try {
    Write-Log "=== BOBJ Content Import Started ==="
    Write-Log "Server URL: $ServerUrl"
    Write-Log "LCMBIAR Path: $LcmbiarPath"
    Write-Log "Conflict Resolution: $ConflictResolution"
    Write-Log "Overwrite Security: $OverwriteSecurity"
    
    # Find LCMBIAR files
    if (Test-Path $LcmbiarPath -PathType Container) {
        $lcmbiarFiles = Get-ChildItem -Path $LcmbiarPath -Filter "*.lcmbiar" -Recurse
        if ($lcmbiarFiles.Count -eq 0) {
            # Also check for files without extension
            $lcmbiarFiles = Get-ChildItem -Path $LcmbiarPath -Recurse -File | Where-Object { $_.Length -gt 0 }
        }
    }
    else {
        $lcmbiarFiles = @(Get-Item $LcmbiarPath)
    }
    
    if ($lcmbiarFiles.Count -eq 0) {
        Write-Log "No LCMBIAR files found" -Level ERROR
        exit 1
    }
    
    Write-Log "Found $($lcmbiarFiles.Count) LCMBIAR file(s)"
    
    # Authenticate
    $logonToken = Get-BOBJSession -ServerUrl $ServerUrl -Username $Username -Password $Password -AuthType $AuthType
    
    $totalImported = 0
    $totalSkipped = 0
    $totalFailed = 0
    $success = $true
    
    foreach ($file in $lcmbiarFiles) {
        Write-Log "Processing: $($file.FullName)"
        
        $result = Import-FromLCMBIAR `
            -ServerUrl $ServerUrl `
            -LogonToken $logonToken `
            -LcmbiarFile $file.FullName `
            -ConflictResolution $ConflictResolution `
            -OverwriteSecurity $OverwriteSecurity
        
        if ($result.Success) {
            $totalImported += $result.ImportedCount
            $totalSkipped += $result.SkippedCount
            $totalFailed += $result.FailedCount
        }
        else {
            $success = $false
            Write-Log "Failed to import $($file.Name): $($result.Error)" -Level ERROR
        }
    }
    
    # Close session
    Close-BOBJSession -ServerUrl $ServerUrl -LogonToken $logonToken
    
    Write-Log "=== Import Summary ==="
    Write-Log "Total imported: $totalImported"
    Write-Log "Total skipped: $totalSkipped"
    Write-Log "Total failed: $totalFailed"
    
    # Set Azure DevOps variables
    Write-Host "##vso[task.setvariable variable=importedCount]$totalImported"
    Write-Host "##vso[task.setvariable variable=skippedCount]$totalSkipped"
    Write-Host "##vso[task.setvariable variable=failedCount]$totalFailed"
    
    if ($success -and $totalFailed -eq 0) {
        Write-Log "=== Import Completed Successfully ===" -Level INFO
        exit 0
    }
    else {
        Write-Log "=== Import Completed with Errors ===" -Level WARN
        exit 1
    }
}
catch {
    Write-Log "Unhandled error: $_" -Level ERROR
    exit 1
}
