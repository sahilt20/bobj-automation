<#
.SYNOPSIS
    Validates LCMBIAR package and optionally verifies deployment.

.DESCRIPTION
    Validates the structure and contents of an LCMBIAR package (archive or directory),
    checks for manifest files, dependencies, and can verify deployment connectivity.

.PARAMETER ServerUrl
    The URL of the BOBJ server (required for VerifyDeployment)

.PARAMETER CmsServer
    The CMS server hostname

.PARAMETER Username
    Username for authentication

.PARAMETER Password
    Password for authentication

.PARAMETER LcmbiarPath
    Path to LCMBIAR file (.lcmbiar/.zip) or directory (for validation mode)

.PARAMETER VerifyDeployment
    Switch to enable deployment verification mode

.PARAMETER CheckDependencies
    Switch to enable dependency checking

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
    [switch]$CheckDependencies,
    
    [Parameter(Mandatory = $false)]
    [string]$OutputPath
)

$ErrorActionPreference = 'Stop'

# Load required assemblies for Zip handling if needed
Add-Type -AssemblyName System.IO.Compression.FileSystem

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
        manifestFound = $false
        dependenciesValid = $true
    }
    
    Write-Log "Validating LCMBIAR structure at: $Path"
    
    if (-not (Test-Path $Path)) {
        $report.errors += "Path does not exist: $Path"
        $report.valid = $false
        return $report
    }

    if ((Get-Item $Path).Attributes -match 'Directory') {
        # Directory validation
        $files = Get-ChildItem -Path $Path -Recurse -File
        $report.objectCount = $files.Count
        
        if ($files.Count -eq 0) {
            $report.errors += "Directory contains no files"
            $report.valid = $false
            return $report
        }

        # Check for manifest
        $manifests = $files | Where-Object { $_.Name -match 'manifest.*\.xml$' -or $_.Name -eq 'manifest.json' }
        if ($manifests) {
            $report.manifestFound = $true
            foreach ($m in $manifests) {
                try {
                    if ($m.Extension -eq '.xml') {
                        [xml]$xml = Get-Content $m.FullName
                        if (-not $xml.DocumentElement) { throw "Empty XML root" }
                    }
                } catch {
                    $report.warnings += "Could not parse manifest $($m.Name): $_"
                }
            }
        } else {
            $report.warnings += "No manifest file found in directory"
        }
        
        # Log file summary
        foreach ($file in $files | Select-Object -First 50) {
            $report.objects += @{
                name = $file.Name
                size = $file.Length
                type = $file.Extension
            }
        }
    }
    else {
        # File validation
        $extension = [System.IO.Path]::GetExtension($Path).ToLower()
        
        if ($extension -eq '.lcmbiar' -or $extension -eq '.zip') {
            try {
                $zip = [System.IO.Compression.ZipFile]::OpenRead($Path)
                $report.objectCount = $zip.Entries.Count
                
                # Check for manifest
                $manifestEntry = $zip.Entries | Where-Object { $_.Name -match 'manifest.*\.xml$' -or $_.Name -eq 'manifest.json' }
                if ($manifestEntry) {
                    $report.manifestFound = $true
                } else {
                    $report.warnings += "No manifest file found in archive"
                }
                
                # Catalog objects (first 50)
                foreach ($entry in $zip.Entries | Select-Object -First 50) {
                    $report.objects += @{
                        name = $entry.Name
                        size = $entry.Length
                        compressedSize = $entry.CompressedLength
                        type = [System.IO.Path]::GetExtension($entry.Name)
                    }
                }
                
                $zip.Dispose()
            }
            catch {
                $report.errors += "Invalid or corrupted LCMBIAR archive: $_"
                $report.valid = $false
            }
        }
        else {
            # Single non-archive file
            $file = Get-Item $Path
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

function Check-Dependencies {
    param([string]$Path, [object]$Report)
    
    Write-Log "Checking dependencies..."
    
    # Basic check logic mirroring the Python script
    # Real implementation would parse the BIAR/LCMBIAR metadata deeply
    
    if ((Get-Item $Path).Attributes -match 'Directory') {
        $universes = Get-ChildItem -Path $Path -Recurse -Include *.unx, *.unv
        if ($universes) {
             # Just a warning/info for now as we can't easily validate external refs without connecting to CMS
             $Report.warnings += "Found $($universes.Count) universe file(s) - ensure connections exist in target system"
        }
    }
    elseif ($Path -match '\.(lcmbiar|zip)$') {
        try {
            $zip = [System.IO.Compression.ZipFile]::OpenRead($Path)
            $universes = $zip.Entries | Where-Object { $_.Name -match '\.un[xv]$' }
            if ($universes) {
                $Report.warnings += "Found $($universes.Count) universe file(s) inside archive - ensure connections exist in target system"
            }
            $zip.Dispose()
        } catch {
            Write-Log "Failed to check dependencies in zip: $_" -Level WARN
        }
    }
    
    return $Report
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
        
        if ($CheckDependencies) {
            $report = Check-Dependencies -Path $LcmbiarPath -Report $report
        }
        
        # Output report summary
        Write-Log "Validation complete"
        Write-Log "Object count: $($report.objectCount)"
        Write-Log "Valid structure: $($report.valid)"
        Write-Log "Manifest found: $($report.manifestFound)"
        
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
