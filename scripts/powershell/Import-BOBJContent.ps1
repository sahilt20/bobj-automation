<#
.SYNOPSIS
    Imports LCMBIAR content to SAP BusinessObjects system using LCMCLI.

.DESCRIPTION
    This script uses the SAP LCMCLI command-line tool to import content
    from an LCMBIAR archive file into a BOBJ system.
    
    LCMCLI uses a .properties file for configuration. This script generates
    the properties file dynamically and invokes lcm_cli.bat.
    
    NOTE: In SAP BI 2025, the /biprws/lcm/ REST endpoints do NOT exist.
    LCMCLI is the supported tool for LCM operations.

.PARAMETER CmsServer
    The CMS server hostname

.PARAMETER CmsPort
    The CMS port (default: 6400)

.PARAMETER Username
    Username for BOBJ authentication

.PARAMETER Password
    Password for BOBJ authentication

.PARAMETER AuthType
    Authentication type (secEnterprise, secLDAP, secWinAD, secSAPR3)

.PARAMETER LcmbiarPath
    Path to the LCMBIAR file or directory containing LCMBIAR files

.PARAMETER LcmbiarPassword
    Optional password to decrypt encrypted LCMBIAR files

.PARAMETER LcmcliPath
    Path to the lcm_cli.bat tool on the BOBJ server

.PARAMETER VerboseLogging
    Enable verbose logging
#>

[CmdletBinding()]
param(
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
    [string]$LcmbiarPassword,
    
    [Parameter(Mandatory = $false)]
    [string]$LcmcliPath = 'C:\Program Files (x86)\SAP BusinessObjects\SAP BusinessObjects Enterprise XI 4.0\win64_x64\scripts\lcm\lcm_cli.bat',
    
    [Parameter(Mandatory = $false)]
    [switch]$VerboseLogging = $false,

    # Legacy parameters - kept for backward compatibility with existing pipelines
    [Parameter(Mandatory = $false)]
    [string]$ServerUrl,
    
    [Parameter(Mandatory = $false)]
    [string]$ConflictResolution,
    
    [Parameter(Mandatory = $false)]
    [switch]$OverwriteSecurity = $false
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

function Test-LcmcliExists {
    param([string]$Path)
    
    if (-not (Test-Path $Path)) {
        Write-Log "LCMCLI not found at: $Path" -Level ERROR
        Write-Log "Ensure SAP BI Client Tools are installed, or set -LcmcliPath to the correct location." -Level ERROR
        throw "LCMCLI tool not found at: $Path"
    }
    
    Write-Log "LCMCLI found at: $Path" -Level DEBUG
}

function New-ImportPropertiesFile {
    param(
        [string]$CmsServer,
        [int]$CmsPort,
        [string]$Username,
        [string]$Password,
        [string]$AuthType,
        [string]$LcmbiarFilePath,
        [string]$LcmbiarPassword,
        [string]$OutputDir
    )
    
    $propertiesPath = Join-Path $OutputDir "lcmcli_import_$(Get-Date -Format 'HHmmss').properties"
    
    # Build properties file content
    $properties = @(
        "# LCMCLI Import Properties (auto-generated)"
        "# Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
        ""
        "action=promote"
        ""
        "# Target CMS Connection"
        "Destination_CMS=${CmsServer}:${CmsPort}"
        "Destination_userName=${Username}"
        "Destination_password=${Password}"
        "Destination_authentication=${AuthType}"
        ""
        "# Source LCMBIAR file"
        "importLocation=$($LcmbiarFilePath -replace '\\', '/')"
    )
    
    if ($LcmbiarPassword) {
        $properties += ""
        $properties += "# LCMBIAR decryption"
        $properties += "lcmbiarpassword=${LcmbiarPassword}"
    }
    
    # Enable logging for verbose mode
    $properties += ""
    $properties += "# Logging"
    $properties += "log=true"
    
    $properties | Out-File -FilePath $propertiesPath -Encoding UTF8
    
    Write-Log "Properties file created: $propertiesPath" -Level DEBUG
    
    return $propertiesPath
}

function Import-FromLCMBIAR {
    param(
        [string]$CmsServer,
        [int]$CmsPort,
        [string]$Username,
        [string]$Password,
        [string]$AuthType,
        [string]$LcmbiarFile,
        [string]$LcmbiarPassword,
        [string]$LcmcliPath
    )
    
    Write-Log "Starting LCMBIAR import: $LcmbiarFile" -Level INFO
    
    $logDir = Split-Path $LcmbiarFile -Parent
    $logBaseName = [System.IO.Path]::GetFileNameWithoutExtension($LcmbiarFile)
    
    # Create properties file
    $propertiesFile = New-ImportPropertiesFile `
        -CmsServer $CmsServer `
        -CmsPort $CmsPort `
        -Username $Username `
        -Password $Password `
        -AuthType $AuthType `
        -LcmbiarFilePath $LcmbiarFile `
        -LcmbiarPassword $LcmbiarPassword `
        -OutputDir $logDir
    
    # Log the properties (mask password)
    $maskedContent = (Get-Content $propertiesFile -Raw) -replace "Destination_password=.*", "Destination_password=********"
    Write-Log "Properties file content:" -Level DEBUG
    $maskedContent -split "`n" | ForEach-Object { Write-Log "  $_" -Level DEBUG }
    
    try {
        $stdoutLog = Join-Path $logDir "${logBaseName}_import_stdout.log"
        $stderrLog = Join-Path $logDir "${logBaseName}_import_stderr.log"
        
        Write-Log "Executing LCMCLI import..." -Level INFO
        
        # Execute LCMCLI with properties file
        $process = Start-Process -FilePath $LcmcliPath `
            -ArgumentList "-lcmproperty `"$propertiesFile`"" `
            -Wait `
            -PassThru `
            -NoNewWindow `
            -RedirectStandardOutput $stdoutLog `
            -RedirectStandardError $stderrLog
        
        # Read output logs
        $stdout = ""
        $stderr = ""
        
        if (Test-Path $stdoutLog) {
            $stdout = Get-Content $stdoutLog -Raw
            if ($stdout) {
                Write-Log "LCMCLI Output:" -Level DEBUG
                $stdout -split "`n" | ForEach-Object { Write-Log "  $_" -Level DEBUG }
            }
        }
        
        if (Test-Path $stderrLog) {
            $stderr = Get-Content $stderrLog -Raw
            if ($stderr) {
                Write-Log "LCMCLI Errors:" -Level WARN
                $stderr -split "`n" | ForEach-Object { Write-Log "  $_" -Level WARN }
            }
        }
        
        # Parse counts from LCMCLI output (best-effort)
        $importedCount = 0
        $skippedCount = 0
        $failedCount = 0
        
        if ($stdout) {
            if ($stdout -match '(?i)imported[:\s]+(\d+)') { $importedCount = [int]$Matches[1] }
            if ($stdout -match '(?i)skipped[:\s]+(\d+)')  { $skippedCount = [int]$Matches[1] }
            if ($stdout -match '(?i)failed[:\s]+(\d+)')   { $failedCount = [int]$Matches[1] }
        }
        
        # Check exit code
        if ($process.ExitCode -ne 0) {
            $errorMsg = if ($stderr) { $stderr } else { "LCMCLI exited with code $($process.ExitCode)" }
            throw "LCMCLI import failed (exit code $($process.ExitCode)): $errorMsg"
        }
        
        Write-Log "Import completed successfully" -Level INFO
        Write-Log "Objects imported: $importedCount" -Level INFO
        Write-Log "Objects skipped: $skippedCount" -Level INFO
        Write-Log "Objects failed: $failedCount" -Level INFO
        
        # Clean up temp files
        Remove-Item $propertiesFile -Force -ErrorAction SilentlyContinue
        Remove-Item $stdoutLog -Force -ErrorAction SilentlyContinue
        Remove-Item $stderrLog -Force -ErrorAction SilentlyContinue
        
        return @{
            Success = $true
            ImportedCount = $importedCount
            SkippedCount = $skippedCount
            FailedCount = $failedCount
        }
    }
    catch {
        Write-Log "Import failed: $_" -Level ERROR
        # Clean up properties file (contains password)
        Remove-Item $propertiesFile -Force -ErrorAction SilentlyContinue
        return @{
            Success = $false
            Error = $_.Exception.Message
        }
    }
}

# Main execution
try {
    Write-Log "=== BOBJ Content Import Started (LCMCLI) ==="
    Write-Log "CMS Server: ${CmsServer}:${CmsPort}"
    Write-Log "LCMBIAR Path: $LcmbiarPath"
    Write-Log "LCMCLI Path: $LcmcliPath"
    
    if ($ServerUrl) {
        Write-Log "NOTE: -ServerUrl parameter is deprecated. LCMCLI connects directly via CMS. Ignoring ServerUrl." -Level WARN
    }
    if ($ConflictResolution) {
        Write-Log "NOTE: -ConflictResolution parameter is not used by LCMCLI promote action. LCMCLI manages conflicts internally." -Level WARN
    }
    
    # Verify LCMCLI tool exists
    Test-LcmcliExists -Path $LcmcliPath
    
    # Find LCMBIAR files
    if (Test-Path $LcmbiarPath -PathType Container) {
        $lcmbiarFiles = Get-ChildItem -Path $LcmbiarPath -Filter "*.lcmbiar" -Recurse
        if ($lcmbiarFiles.Count -eq 0) {
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
    
    $totalImported = 0
    $totalSkipped = 0
    $totalFailed = 0
    $success = $true
    
    foreach ($file in $lcmbiarFiles) {
        Write-Log "Processing: $($file.FullName)"
        
        $result = Import-FromLCMBIAR `
            -CmsServer $CmsServer `
            -CmsPort $CmsPort `
            -Username $Username `
            -Password $Password `
            -AuthType $AuthType `
            -LcmbiarFile $file.FullName `
            -LcmbiarPassword $LcmbiarPassword `
            -LcmcliPath $LcmcliPath
        
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
