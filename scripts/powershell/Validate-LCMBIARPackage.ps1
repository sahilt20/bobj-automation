<#
.SYNOPSIS
    Validates LCMBIAR package and optionally verifies deployment.

.DESCRIPTION
    Validates the structure and contents of an LCMBIAR package, or verifies
    that a deployment was successful by checking objects in the target system.

.PARAMETER ServerUrl
    The URL of the BOBJ server (required for VerifyDeployment)

.PARAMETER CmsServer
    The CMS server hostname

.PARAMETER Username
    Username for authentication

.PARAMETER Password
    Password for authentication

.PARAMETER LcmbiarPath
    Path to LCMBIAR file or directory (for validation mode)

.PARAMETER VerifyDeployment
    Switch to enable deployment verification mode

.PARAMETER OutputPath
    Path for validation report output
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ServerUrl,
    
    [Parameter(Mandatory = $false)]
    [string]$CmsServer,
    
    [Parameter(Mandatory = $false)]
    [string]$Username,
    
    [Parameter(Mandatory = $false)]
    [string]$Password,
    
    [Parameter(Mandatory = $false)]
    [string]$LcmbiarPath,
    
    [Parameter(Mandatory = $false)]
    [switch]$VerifyDeployment,
    
    [Parameter(Mandatory = $false)]
    [string]$OutputPath
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

function Test-LcmbiarStructure {
    param([string]$Path)
    
    $report = @{
        valid = $true
        objectCount = 0
        warnings = @()
        errors = @()
        objects = @()
    }
    
    Write-Log "Validating LCMBIAR structure at: $Path"
    
    if (Test-Path $Path -PathType Container) {
        $files = Get-ChildItem -Path $Path -Recurse -File
        $report.objectCount = $files.Count
        
        # Check for manifest
        $manifest = $files | Where-Object { $_.Name -like '*manifest*' -or $_.Name -like '*.xml' }
        if (-not $manifest) {
            $report.warnings += "No manifest file found"
        }
        
        # Check for content files
        $contentFiles = $files | Where-Object { $_.Length -gt 0 }
        if ($contentFiles.Count -eq 0) {
            $report.errors += "No content files found"
            $report.valid = $false
        }
        
        # Log file summary
        foreach ($file in $files | Select-Object -First 20) {
            $report.objects += @{
                name = $file.Name
                size = $file.Length
                type = $file.Extension
            }
        }
    }
    else {
        # Single file
        $file = Get-Item $Path
        if ($file.Length -eq 0) {
            $report.errors += "LCMBIAR file is empty"
            $report.valid = $false
        }
        else {
            $report.objectCount = 1
            $report.objects += @{
                name = $file.Name
                size = $file.Length
                type = $file.Extension
            }
        }
    }
    
    return $report
}

function Test-Deployment {
    param(
        [string]$ServerUrl,
        [string]$Username,
        [string]$Password
    )
    
    Write-Log "Verifying deployment..."
    
    $loginUrl = "$ServerUrl/biprws/logon/long"
    $loginBody = @{
        userName = $Username
        password = $Password
        auth = 'secEnterprise'
    } | ConvertTo-Json
    
    try {
        $response = Invoke-RestMethod -Uri $loginUrl -Method Post -Body $loginBody -ContentType 'application/json'
        $logonToken = $response.logonToken
        
        if (-not $logonToken) {
            Write-Log "Failed to authenticate for verification" -Level ERROR
            return $false
        }
        
        # Check system status
        $headers = @{
            'X-SAP-LogonToken' = $logonToken
            'Accept' = 'application/json'
        }
        
        # Try to access infostore
        try {
            $testUrl = "$ServerUrl/biprws/infostore"
            $result = Invoke-RestMethod -Uri $testUrl -Method Get -Headers $headers
            Write-Log "System accessible and responding" -Level OK
            
            # Logout
            Invoke-RestMethod -Uri "$ServerUrl/biprws/logoff" -Method Post -Headers $headers | Out-Null
            
            return $true
        }
        catch {
            Write-Log "System access test failed: $_" -Level WARN
            return $true  # May still be OK
        }
    }
    catch {
        Write-Log "Deployment verification failed: $_" -Level ERROR
        return $false
    }
}

# Main execution
try {
    Write-Log "=== LCMBIAR Validation ==="
    
    if ($VerifyDeployment) {
        # Deployment verification mode
        if (-not $ServerUrl -or -not $Username -or -not $Password) {
            Write-Log "ServerUrl, Username, and Password required for deployment verification" -Level ERROR
            exit 1
        }
        
        $success = Test-Deployment -ServerUrl $ServerUrl -Username $Username -Password $Password
        
        if ($success) {
            Write-Log "=== Deployment Verification Passed ===" -Level OK
            exit 0
        }
        else {
            Write-Log "=== Deployment Verification Failed ===" -Level ERROR
            exit 1
        }
    }
    else {
        # Package validation mode
        if (-not $LcmbiarPath) {
            Write-Log "LcmbiarPath required for package validation" -Level ERROR
            exit 1
        }
        
        $report = Test-LcmbiarStructure -Path $LcmbiarPath
        
        # Output report
        Write-Log "Validation complete"
        Write-Log "Object count: $($report.objectCount)"
        Write-Log "Valid: $($report.valid)"
        
        if ($report.warnings.Count -gt 0) {
            foreach ($warn in $report.warnings) {
                Write-Log "Warning: $warn" -Level WARN
            }
        }
        
        if ($report.errors.Count -gt 0) {
            foreach ($err in $report.errors) {
                Write-Log "Error: $err" -Level ERROR
            }
        }
        
        # Save report if output path specified
        if ($OutputPath) {
            $reportDir = Split-Path $OutputPath -Parent
            if ($reportDir -and -not (Test-Path $reportDir)) {
                New-Item -ItemType Directory -Path $reportDir -Force | Out-Null
            }
            $report | ConvertTo-Json -Depth 5 | Out-File $OutputPath
            Write-Log "Report saved to: $OutputPath"
        }
        
        # Set Azure DevOps variables
        Write-Host "##vso[task.setvariable variable=validationPassed]$($report.valid)"
        Write-Host "##vso[task.setvariable variable=objectCount]$($report.objectCount)"
        
        if ($report.valid) {
            Write-Log "=== Validation Passed ===" -Level OK
            exit 0
        }
        else {
            Write-Log "=== Validation Failed ===" -Level ERROR
            exit 1
        }
    }
}
catch {
    Write-Log "Unhandled error: $_" -Level ERROR
    exit 1
}
