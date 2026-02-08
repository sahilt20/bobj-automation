<#
.SYNOPSIS
    Exports SAP BusinessObjects content to LCMBIAR archive via Raylight REST API.

.DESCRIPTION
    Connects to a SAP BusinessObjects system using the Raylight REST API (biprws)
    and exports content (reports, universes, connections, folders) to an LCMBIAR
    file for promotion/transport to higher environments.

.PARAMETER ServerUrl
    The base URL of the BOBJ server (e.g., https://bobj-server:8080)

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
    .\Export-BOBJContent.ps1 -ServerUrl "https://bobj:8080" -CmsServer "bobj-cms" -Username "admin" -Password "pass" -ExportFolder "/Public Folders" -OutputPath "./export"
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

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# Raylight REST API helpers
# ---------------------------------------------------------------------------
function Get-RaylightSession {
    param(
        [string]$ServerUrl,
        [string]$Username,
        [string]$Password,
        [string]$AuthType
    )
    Write-Log "Authenticating to BOBJ via Raylight API: $ServerUrl" -Level INFO

    $loginUrl = "$ServerUrl/biprws/logon/long"
    $loginBody = @"
<attrs xmlns="http://www.sap.com/rws/bip">
  <attr name="userName" type="string">$Username</attr>
  <attr name="password" type="string">$Password</attr>
  <attr name="auth" type="string" possibilities="secEnterprise,secLDAP,secWinAD,secSAPR3">$AuthType</attr>
</attrs>
"@

    try {
        $response = Invoke-RestMethod -Uri $loginUrl -Method Post -Body $loginBody `
            -ContentType 'application/xml' -Headers @{ 'Accept' = 'application/json' }

        $logonToken = $response.logonToken
        if (-not $logonToken) {
            throw "No logonToken in response"
        }
        Write-Log "Authentication successful" -Level INFO
        return $logonToken
    }
    catch {
        Write-Log "Authentication failed: $_" -Level ERROR
        throw
    }
}

function Test-RaylightHealth {
    param(
        [string]$ServerUrl,
        [string]$LogonToken
    )
    Write-Log "Checking Raylight API health..." -Level DEBUG
    $headers = @{
        'X-SAP-LogonToken' = "`"$LogonToken`""
        'Accept'           = 'application/json'
    }
    try {
        $about = Invoke-RestMethod -Uri "$ServerUrl/biprws/raylight/v1/about" -Method Get -Headers $headers
        Write-Log "Raylight API healthy - version: $($about.version)" -Level INFO
        return $about
    }
    catch {
        Write-Log "Raylight API health check failed: $_" -Level ERROR
        throw
    }
}

function Resolve-FolderPath {
    param(
        [string]$ServerUrl,
        [string]$LogonToken,
        [string]$FolderPath
    )
    Write-Log "Resolving folder path: $FolderPath" -Level DEBUG
    $headers = @{
        'X-SAP-LogonToken' = "`"$LogonToken`""
        'Accept'           = 'application/json'
    }
    Add-Type -AssemblyName System.Web
    $encodedPath = [System.Web.HttpUtility]::UrlEncode($FolderPath)
    $url = "$ServerUrl/biprws/infostore/folder?path=$encodedPath"
    try {
        $folderInfo = Invoke-RestMethod -Uri $url -Method Get -Headers $headers
        $folderId = $folderInfo.entries.id
        if (-not $folderId) {
            $folderId = $folderInfo.id
        }
        if (-not $folderId) {
            throw "Could not resolve folder ID for path: $FolderPath"
        }
        Write-Log "Folder resolved - ID: $folderId" -Level DEBUG
        return $folderId
    }
    catch {
        Write-Log "Failed to resolve folder: $_" -Level ERROR
        throw
    }
}

function New-PromotionJob {
    param(
        [string]$ServerUrl,
        [string]$LogonToken,
        [string]$FolderId,
        [string]$FolderPath,
        [bool]$IncludeSecurity,
        [bool]$IncludeDeps
    )
    Write-Log "Creating promotion export job for folder ID: $FolderId" -Level INFO
    $headers = @{
        'X-SAP-LogonToken' = "`"$LogonToken`""
        'Accept'           = 'application/json'
        'Content-Type'     = 'application/json'
    }

    $jobName = "Export_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
    $jobBody = @{
        name                = $jobName
        description         = "CI/CD export of $FolderPath"
        sourceType          = 'folder'
        sourceId            = $FolderId
        includeSecurityRights = $IncludeSecurity
        includeDependencies = $IncludeDeps
        exportFormat        = 'lcmbiar'
    } | ConvertTo-Json

    try {
        $response = Invoke-RestMethod -Uri "$ServerUrl/biprws/promotion/" -Method Post `
            -Headers $headers -Body $jobBody
        $jobId = $response.id
        if (-not $jobId) {
            throw "No job ID returned from promotion API"
        }
        Write-Log "Promotion job created: $jobId ($jobName)" -Level INFO
        return @{ Id = $jobId; Name = $jobName }
    }
    catch {
        Write-Log "Failed to create promotion job: $_" -Level ERROR
        throw
    }
}

function Start-Promotion {
    param(
        [string]$ServerUrl,
        [string]$LogonToken,
        [string]$JobId
    )
    Write-Log "Starting promotion job: $JobId" -Level INFO
    $headers = @{
        'X-SAP-LogonToken' = "`"$LogonToken`""
        'Accept'           = 'application/json'
        'Content-Type'     = 'application/json'
    }
    try {
        Invoke-RestMethod -Uri "$ServerUrl/biprws/promotion/$JobId/execute" -Method Post -Headers $headers | Out-Null
        Write-Log "Promotion job started" -Level INFO
    }
    catch {
        Write-Log "Failed to start promotion: $_" -Level ERROR
        throw
    }
}

function Wait-ForPromotion {
    param(
        [string]$ServerUrl,
        [string]$LogonToken,
        [string]$JobId,
        [int]$TimeoutMinutes = 30,
        [int]$PollIntervalSeconds = 5
    )
    Write-Log "Waiting for promotion job $JobId to complete (timeout: ${TimeoutMinutes}m)..." -Level INFO
    $headers = @{
        'X-SAP-LogonToken' = "`"$LogonToken`""
        'Accept'           = 'application/json'
    }

    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    $statusUrl = "$ServerUrl/biprws/promotion/$JobId"

    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds $PollIntervalSeconds
        try {
            $status = Invoke-RestMethod -Uri $statusUrl -Method Get -Headers $headers
            $state = $status.status
            if (-not $state) { $state = $status.state }
            Write-Log "Job $JobId status: $state" -Level DEBUG

            switch -Wildcard ($state) {
                'Completed'  { Write-Log "Promotion job completed successfully" -Level INFO; return $status }
                'Success'    { Write-Log "Promotion job completed successfully" -Level INFO; return $status }
                'Failed'     { throw "Promotion job failed: $($status.errorMessage)" }
                'Error'      { throw "Promotion job error: $($status.errorMessage)" }
                'Cancelled'  { throw "Promotion job was cancelled" }
            }
        }
        catch [System.Net.WebException] {
            Write-Log "Transient error polling status, retrying... $_" -Level WARN
        }
    }
    throw "Promotion job $JobId timed out after $TimeoutMinutes minutes"
}

function Get-LcmbiarDownload {
    param(
        [string]$ServerUrl,
        [string]$LogonToken,
        [string]$JobId,
        [string]$OutputPath
    )
    Write-Log "Downloading LCMBIAR from promotion job: $JobId" -Level INFO

    $headers = @{
        'X-SAP-LogonToken' = "`"$LogonToken`""
        'Accept'           = 'application/octet-stream'
    }

    if (-not (Test-Path $OutputPath)) {
        New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
    }

    $lcmbiarFile = Join-Path $OutputPath "export_$(Get-Date -Format 'yyyyMMdd_HHmmss').lcmbiar"
    $downloadUrl = "$ServerUrl/biprws/promotion/$JobId/lcmbiar"

    try {
        Invoke-WebRequest -Uri $downloadUrl -Method Get -Headers $headers -OutFile $lcmbiarFile
        $fileInfo = Get-Item $lcmbiarFile
        Write-Log "LCMBIAR downloaded: $lcmbiarFile ($([math]::Round($fileInfo.Length / 1MB, 2)) MB)" -Level INFO
        return $lcmbiarFile
    }
    catch {
        Write-Log "Failed to download LCMBIAR: $_" -Level ERROR
        throw
    }
}

function New-ExportManifest {
    param(
        [string]$LcmbiarPath,
        [string]$JobId,
        [string]$SourceFolder,
        [string]$ServerUrl
    )
    $fileInfo = Get-Item $LcmbiarPath
    $sha256 = (Get-FileHash -Path $LcmbiarPath -Algorithm SHA256).Hash

    $manifest = @{
        exportTimestamp = (Get-Date -Format 'o')
        sourceServer   = $ServerUrl
        sourceFolder   = $SourceFolder
        promotionJobId = $JobId
        lcmbiarFile    = $fileInfo.Name
        lcmbiarSizeBytes = $fileInfo.Length
        sha256Checksum = $sha256
        exportedBy     = $env:BUILD_REQUESTEDFOR
        buildId        = $env:BUILD_BUILDID
        buildNumber    = $env:BUILD_BUILDNUMBER
    } | ConvertTo-Json -Depth 5

    $manifestPath = [System.IO.Path]::ChangeExtension($LcmbiarPath, '.manifest.json')
    $manifest | Out-File -FilePath $manifestPath -Encoding UTF8
    Write-Log "Export manifest written: $manifestPath" -Level INFO
    return @{ ManifestPath = $manifestPath; SHA256 = $sha256 }
}

function Close-RaylightSession {
    param(
        [string]$ServerUrl,
        [string]$LogonToken
    )
    Write-Log "Closing Raylight session..." -Level DEBUG
    $headers = @{
        'X-SAP-LogonToken' = "`"$LogonToken`""
    }
    try {
        Invoke-RestMethod -Uri "$ServerUrl/biprws/logoff" -Method Post -Headers $headers | Out-Null
        Write-Log "Session closed" -Level DEBUG
    }
    catch {
        Write-Log "Failed to close session cleanly: $_" -Level WARN
    }
}

# ---------------------------------------------------------------------------
# Main execution
# ---------------------------------------------------------------------------
$logonToken = $null
try {
    Write-Log "=== BOBJ Content Export (Raylight API) ===" -Level INFO
    Write-Log "Server: $ServerUrl" -Level INFO
    Write-Log "CMS: ${CmsServer}:${CmsPort}" -Level INFO
    Write-Log "Export Folder: $ExportFolder" -Level INFO
    Write-Log "Output Path: $OutputPath" -Level INFO
    Write-Log "Security: $IncludeSecurityRights | Dependencies: $IncludeDependencies | Backup: $BackupMode" -Level INFO

    # Step 1: Authenticate via Raylight logon
    $logonToken = Get-RaylightSession -ServerUrl $ServerUrl -Username $Username -Password $Password -AuthType $AuthType

    # Step 2: Health check
    $aboutInfo = Test-RaylightHealth -ServerUrl $ServerUrl -LogonToken $logonToken

    # Step 3: Resolve export folder to ID
    $folderId = Resolve-FolderPath -ServerUrl $ServerUrl -LogonToken $logonToken -FolderPath $ExportFolder

    # Step 4: Create promotion export job
    $job = New-PromotionJob -ServerUrl $ServerUrl -LogonToken $logonToken `
        -FolderId $folderId -FolderPath $ExportFolder `
        -IncludeSecurity $IncludeSecurityRights -IncludeDeps $IncludeDependencies

    # Step 5: Execute the promotion job
    Start-Promotion -ServerUrl $ServerUrl -LogonToken $logonToken -JobId $job.Id

    # Step 6: Poll until completion
    $completedJob = Wait-ForPromotion -ServerUrl $ServerUrl -LogonToken $logonToken `
        -JobId $job.Id -TimeoutMinutes 30

    # Step 7: Download LCMBIAR archive
    $lcmbiarFile = Get-LcmbiarDownload -ServerUrl $ServerUrl -LogonToken $logonToken `
        -JobId $job.Id -OutputPath $OutputPath

    # Step 8: Generate manifest with checksum
    $manifestResult = New-ExportManifest -LcmbiarPath $lcmbiarFile -JobId $job.Id `
        -SourceFolder $ExportFolder -ServerUrl $ServerUrl

    # Step 9: Close session
    Close-RaylightSession -ServerUrl $ServerUrl -LogonToken $logonToken
    $logonToken = $null

    Write-Log "=== Export Completed Successfully ===" -Level INFO
    Write-Log "LCMBIAR: $lcmbiarFile" -Level INFO
    Write-Log "SHA256: $($manifestResult.SHA256)" -Level INFO

    # Azure DevOps output variables
    Write-Host "##vso[task.setvariable variable=lcmbiarPath;isOutput=true]$lcmbiarFile"
    Write-Host "##vso[task.setvariable variable=lcmbiarSHA256;isOutput=true]$($manifestResult.SHA256)"
    Write-Host "##vso[task.setvariable variable=exportJobId;isOutput=true]$($job.Id)"
    Write-Host "##vso[task.setvariable variable=manifestPath;isOutput=true]$($manifestResult.ManifestPath)"

    exit 0
}
catch {
    Write-Log "=== Export Failed ===" -Level ERROR
    Write-Log "Error: $($_.Exception.Message)" -Level ERROR
    Write-Log $_.ScriptStackTrace -Level ERROR
    Write-Host "##vso[task.logissue type=error]BOBJ export failed: $($_.Exception.Message)"
    exit 1
}
finally {
    if ($logonToken) {
        Close-RaylightSession -ServerUrl $ServerUrl -LogonToken $logonToken
    }
}
