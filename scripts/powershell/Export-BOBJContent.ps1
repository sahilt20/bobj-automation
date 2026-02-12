<#
.SYNOPSIS
    Exports SAP BusinessObjects content to LCMBIAR archive using LCMCLI.

.DESCRIPTION
    This script uses the SAP LCMCLI command-line tool to export content
    (reports, universes, connections, folders) to an LCMBIAR file for transport.
    
    LCMCLI uses a .properties file for configuration. This script generates
    the properties file dynamically and invokes lcm_cli.bat.
    
    NOTE: In SAP BI 2025, the /biprws/lcm/ REST endpoints do NOT exist.
    LCMCLI is the supported tool for LCM operations.

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

.PARAMETER ExportQuery
    Optional CMS query string. If not provided, defaults to exporting all objects under ExportFolder.

.PARAMETER IncludeSecurityRights
    Include security rights in the export

.PARAMETER LcmcliPath
    Path to the lcm_cli.bat tool on the BOBJ server

.PARAMETER LcmbiarPassword
    Optional password to encrypt the LCMBIAR file

.PARAMETER BackupMode
    Run in backup mode (exports all content for recovery purposes)

.PARAMETER VerboseLogging
    Enable verbose logging

.EXAMPLE
    .\Export-BOBJContent.ps1 -CmsServer "bobj-cms" -Username "admin" -Password "pass" -ExportFolder "/Public Folders" -OutputPath "./export"
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
    
    [Parameter(Mandatory = $false)]
    [string]$ExportFolder = '/Public Folders',
    
    [Parameter(Mandatory = $true)]
    [string]$OutputPath,
    
    [Parameter(Mandatory = $false)]
    [string]$ExportQuery,
    
    [Parameter(Mandatory = $false)]
    [switch]$IncludeSecurityRights = $true,
    
    [Parameter(Mandatory = $false)]
    [string]$LcmcliPath = 'C:\Program Files (x86)\SAP BusinessObjects\SAP BusinessObjects Enterprise XI 4.0\win64_x64\scripts\lcm\lcm_cli.bat',
    
    [Parameter(Mandatory = $false)]
    [string]$LcmbiarPassword,
    
    [Parameter(Mandatory = $false)]
    [switch]$BackupMode = $false,
    
    [Parameter(Mandatory = $false)]
    [switch]$VerboseLogging = $false,

    # Legacy parameter - kept for backward compatibility with existing pipelines
    [Parameter(Mandatory = $false)]
    [string]$ServerUrl
)

# Set error action preference
$ErrorActionPreference = 'Stop'

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

function Test-LcmcliExists {
    param([string]$Path)
    
    if (-not (Test-Path $Path)) {
        Write-Log "LCMCLI not found at: $Path" -Level ERROR
        Write-Log "Ensure SAP BI Client Tools are installed, or set -LcmcliPath to the correct location." -Level ERROR
        throw "LCMCLI tool not found at: $Path"
    }
    
    Write-Log "LCMCLI found at: $Path" -Level DEBUG
}

function New-ExportPropertiesFile {
    param(
        [string]$CmsServer,
        [int]$CmsPort,
        [string]$Username,
        [string]$Password,
        [string]$AuthType,
        [string]$ExportFolder,
        [string]$ExportQuery,
        [string]$LcmbiarFilePath,
        [bool]$IncludeSecurity,
        [string]$LcmbiarPassword,
        [string]$OutputDir
    )
    
    $propertiesPath = Join-Path $OutputDir "lcmcli_export.properties"
    
    # Build the CMS query
    if (-not $ExportQuery) {
        # Default: export everything under the specified folder
        $ExportQuery = "select * from ci_Infoobjects where si_path like '${ExportFolder}%'"
    }
    
    # Build properties file content
    $properties = @(
        "# LCMCLI Export Properties (auto-generated)"
        "# Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
        ""
        "action=export"
        ""
        "# CMS Connection"
        "LCM_CMS=${CmsServer}:${CmsPort}"
        "LCM_userName=${Username}"
        "LCM_password=${Password}"
        "LCM_authentication=${AuthType}"
        ""
        "# Export output"
        "exportLocation=$($LcmbiarFilePath -replace '\\', '/')"
        ""
        "# Export query"
        "exportQuery1=${ExportQuery}"
        "maxQueries=1"
        ""
        "# Security"
        "exportSecurity=$($IncludeSecurity.ToString().ToLower())"
    )
    
    if ($LcmbiarPassword) {
        $properties += ""
        $properties += "# LCMBIAR encryption"
        $properties += "lcmbiarpassword=${LcmbiarPassword}"
    }
    
    $properties | Out-File -FilePath $propertiesPath -Encoding UTF8
    
    Write-Log "Properties file created: $propertiesPath" -Level DEBUG
    
    return $propertiesPath
}

function Export-ToLCMBIAR {
    param(
        [string]$CmsServer,
        [int]$CmsPort,
        [string]$Username,
        [string]$Password,
        [string]$AuthType,
        [string]$FolderPath,
        [string]$ExportQuery,
        [string]$OutputPath,
        [bool]$IncludeSecurity,
        [string]$LcmbiarPassword,
        [string]$LcmcliPath
    )
    
    Write-Log "Starting LCMBIAR export from: $FolderPath" -Level INFO
    
    # Ensure output directory exists
    if (-not (Test-Path $OutputPath)) {
        New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
        Write-Log "Created output directory: $OutputPath" -Level DEBUG
    }
    
    # Generate output filename
    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $lcmbiarFile = Join-Path $OutputPath "export_$timestamp.lcmbiar"
    
    # Create properties file
    $propertiesFile = New-ExportPropertiesFile `
        -CmsServer $CmsServer `
        -CmsPort $CmsPort `
        -Username $Username `
        -Password $Password `
        -AuthType $AuthType `
        -ExportFolder $FolderPath `
        -ExportQuery $ExportQuery `
        -LcmbiarFilePath $lcmbiarFile `
        -IncludeSecurity $IncludeSecurity `
        -LcmbiarPassword $LcmbiarPassword `
        -OutputDir $OutputPath
    
    # Log the properties (mask password)
    $maskedContent = (Get-Content $propertiesFile -Raw) -replace "LCM_password=.*", "LCM_password=********"
    Write-Log "Properties file content:" -Level DEBUG
    $maskedContent -split "`n" | ForEach-Object { Write-Log "  $_" -Level DEBUG }
    
    try {
        Write-Log "Executing LCMCLI export..." -Level INFO
        
        $stdoutLog = Join-Path $OutputPath "lcmcli_stdout.log"
        $stderrLog = Join-Path $OutputPath "lcmcli_stderr.log"
        
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
        
        # Check exit code
        if ($process.ExitCode -ne 0) {
            $errorMsg = if ($stderr) { $stderr } else { "LCMCLI exited with code $($process.ExitCode)" }
            throw "LCMCLI export failed (exit code $($process.ExitCode)): $errorMsg"
        }
        
        # Verify LCMBIAR file was created
        if (-not (Test-Path $lcmbiarFile)) {
            throw "LCMCLI completed but LCMBIAR file was not found at: $lcmbiarFile"
        }
        
        $fileSize = (Get-Item $lcmbiarFile).Length
        Write-Log "LCMBIAR file created: $lcmbiarFile ($([math]::Round($fileSize / 1MB, 2)) MB)" -Level INFO
        
        # Clean up temp files
        Remove-Item $propertiesFile -Force -ErrorAction SilentlyContinue
        Remove-Item $stdoutLog -Force -ErrorAction SilentlyContinue
        Remove-Item $stderrLog -Force -ErrorAction SilentlyContinue
        
        return @{
            Success = $true
            FilePath = $lcmbiarFile
            FileSize = $fileSize
        }
    }
    catch {
        Write-Log "Export failed: $_" -Level ERROR
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
    Write-Log "=== BOBJ Content Export Started (LCMCLI) ===" -Level INFO
    Write-Log "CMS Server: ${CmsServer}:${CmsPort}" -Level INFO
    Write-Log "Export Folder: $ExportFolder" -Level INFO
    Write-Log "Output Path: $OutputPath" -Level INFO
    Write-Log "Include Security: $IncludeSecurityRights" -Level INFO
    Write-Log "Backup Mode: $BackupMode" -Level INFO
    Write-Log "LCMCLI Path: $LcmcliPath" -Level INFO
    
    if ($ServerUrl) {
        Write-Log "NOTE: -ServerUrl parameter is deprecated. LCMCLI connects directly via CMS. Ignoring ServerUrl." -Level WARN
    }
    
    # Verify LCMCLI tool exists
    Test-LcmcliExists -Path $LcmcliPath
    
    # Export content
    $exportResult = Export-ToLCMBIAR `
        -CmsServer $CmsServer `
        -CmsPort $CmsPort `
        -Username $Username `
        -Password $Password `
        -AuthType $AuthType `
        -FolderPath $ExportFolder `
        -ExportQuery $ExportQuery `
        -OutputPath $OutputPath `
        -IncludeSecurity $IncludeSecurityRights `
        -LcmbiarPassword $LcmbiarPassword `
        -LcmcliPath $LcmcliPath
    
    if ($exportResult.Success) {
        Write-Log "=== Export Completed Successfully ===" -Level INFO
        Write-Log "LCMBIAR file: $($exportResult.FilePath)" -Level INFO
        
        # Output for Azure DevOps
        Write-Host "##vso[task.setvariable variable=lcmbiarPath]$($exportResult.FilePath)"
        Write-Host "##vso[task.setvariable variable=lcmbiarSize]$($exportResult.FileSize)"
        
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
