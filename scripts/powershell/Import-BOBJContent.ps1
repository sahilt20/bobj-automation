<#
.SYNOPSIS
    Imports LCMBIAR content into SAP BusinessObjects via Raylight REST API.

.DESCRIPTION
    Connects to SAP BOBJ using the Raylight RESTful Web Services SDK and the
    Promotion Management API to import LCMBIAR archives.

    Workflow:
        1. Authenticate via /biprws/logon/long
        2. Health check via /biprws/raylight/v1/about
        3. Validate LCMBIAR file and compute SHA256
        4. Upload LCMBIAR via POST /biprws/promotion/ (multipart)
        5. Poll for completion via GET /biprws/promotion/{id}
        6. Retrieve results via GET /biprws/promotion/{id}/results
        7. Logoff via /biprws/logoff

.PARAMETER ServerUrl
    Base URL of the target BOBJ web application server

.PARAMETER CmsServer
    CMS server hostname

.PARAMETER CmsPort
    CMS port (default 6400)

.PARAMETER Username
    BOBJ service account username

.PARAMETER Password
    BOBJ service account password

.PARAMETER AuthType
    Authentication type: secEnterprise | secLDAP | secWinAD | secSAPR3

.PARAMETER LcmbiarPath
    Path to the LCMBIAR file or directory containing LCMBIAR files

.PARAMETER ConflictResolution
    Strategy: UpdateExisting | SkipExisting | RenameNew | Fail

.PARAMETER OverwriteSecurity
    Overwrite security settings on target objects

.PARAMETER TargetFolder
    Optional target folder path for import

.PARAMETER ValidateChecksum
    Verify SHA256 checksum from export manifest before import

.PARAMETER ExpectedChecksum
    Expected SHA256 checksum (from CI artifact)

.PARAMETER JobTimeoutSeconds
    Maximum wait time for import job (default 1800)

.PARAMETER PollIntervalSeconds
    Interval between status polls (default 10)

.PARAMETER VerboseLogging
    Enable debug-level logging
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$ServerUrl,
    [Parameter(Mandatory=$true)][string]$CmsServer,
    [Parameter(Mandatory=$false)][int]$CmsPort = 6400,
    [Parameter(Mandatory=$true)][string]$Username,
    [Parameter(Mandatory=$true)][string]$Password,
    [Parameter(Mandatory=$false)][ValidateSet('secEnterprise','secLDAP','secWinAD','secSAPR3')][string]$AuthType = 'secEnterprise',
    [Parameter(Mandatory=$true)][string]$LcmbiarPath,
    [Parameter(Mandatory=$false)][ValidateSet('UpdateExisting','SkipExisting','RenameNew','Fail')][string]$ConflictResolution = 'UpdateExisting',
    [Parameter(Mandatory=$false)][switch]$OverwriteSecurity,
    [Parameter(Mandatory=$false)][string]$TargetFolder,
    [Parameter(Mandatory=$false)][switch]$ValidateChecksum,
    [Parameter(Mandatory=$false)][string]$ExpectedChecksum,
    [Parameter(Mandatory=$false)][int]$JobTimeoutSeconds = 1800,
    [Parameter(Mandatory=$false)][int]$PollIntervalSeconds = 10,
    [Parameter(Mandatory=$false)][switch]$VerboseLogging
)

$ErrorActionPreference = 'Stop'

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$ts] [$Level] $Message"
    switch ($Level) {
        'ERROR' { Write-Host $line -ForegroundColor Red }
        'WARN'  { Write-Host $line -ForegroundColor Yellow }
        'DEBUG' { if ($VerboseLogging) { Write-Host $line -ForegroundColor Gray } }
        default { Write-Host $line }
    }
}

function Get-RaylightSession {
    param([string]$ServerUrl, [string]$Username, [string]$Password, [string]$AuthType)
    Write-Log "Authenticating to $ServerUrl via /biprws/logon/long"
    $body = @{ userName = $Username; password = $Password; auth = $AuthType } | ConvertTo-Json
    $headers = @{ 'Accept' = 'application/json'; 'Content-Type' = 'application/json' }
    $resp = Invoke-RestMethod -Uri "$ServerUrl/biprws/logon/long" -Method Post -Body $body -Headers $headers
    if (-not $resp.logonToken) { throw "No logonToken in response" }
    Write-Log "Authentication successful"
    return $resp.logonToken
}

function Test-RaylightHealth {
    param([string]$ServerUrl, [string]$LogonToken)
    $headers = @{ 'X-SAP-LogonToken' = """$LogonToken"""; 'Accept' = 'application/json' }
    try {
        $info = Invoke-RestMethod -Uri "$ServerUrl/biprws/raylight/v1/about" -Method Get -Headers $headers
        Write-Log "Target BOBJ: $($info.productName) v$($info.productVersion)"
        return $info
    }
    catch { Write-Log "Raylight health check failed: $_" -Level WARN; return $null }
}

function Import-LcmbiarViaPromotion {
    param(
        [string]$ServerUrl, [string]$LogonToken, [string]$LcmbiarFile,
        [string]$ConflictResolution, [bool]$OverwriteSecurity, [string]$TargetFolder
    )
    $fileName = Split-Path $LcmbiarFile -Leaf
    $fileSize = (Get-Item $LcmbiarFile).Length
    Write-Log "Uploading LCMBIAR: $fileName ($fileSize bytes)"

    $conflictMap = @{ 'UpdateExisting'='overwrite'; 'SkipExisting'='skip'; 'RenameNew'='rename'; 'Fail'='fail' }
    $boundary = [System.Guid]::NewGuid().ToString()
    $fileBytes = [System.IO.File]::ReadAllBytes($LcmbiarFile)
    $parts = [System.Collections.ArrayList]::new()
    $enc = [System.Text.Encoding]::UTF8
    $nl = "`r`n"

    # File part
    [void]$parts.Add($enc.GetBytes("--$boundary$nl"))
    [void]$parts.Add($enc.GetBytes("Content-Disposition: form-data; name=`"file`"; filename=`"$fileName`"$nl"))
    [void]$parts.Add($enc.GetBytes("Content-Type: application/octet-stream$nl$nl"))
    [void]$parts.Add($fileBytes)
    [void]$parts.Add($enc.GetBytes($nl))

    # Form fields
    foreach ($kv in @(@("lcmType","import"), @("conflictResolution",$conflictMap[$ConflictResolution]), @("overwriteSecurity",$OverwriteSecurity.ToString().ToLower()))) {
        [void]$parts.Add($enc.GetBytes("--$boundary$nl"))
        [void]$parts.Add($enc.GetBytes("Content-Disposition: form-data; name=`"$($kv[0])`"$nl$nl"))
        [void]$parts.Add($enc.GetBytes("$($kv[1])$nl"))
    }
    if ($TargetFolder) {
        [void]$parts.Add($enc.GetBytes("--$boundary$nl"))
        [void]$parts.Add($enc.GetBytes("Content-Disposition: form-data; name=`"targetFolder`"$nl$nl"))
        [void]$parts.Add($enc.GetBytes("$TargetFolder$nl"))
    }
    [void]$parts.Add($enc.GetBytes("--$boundary--$nl"))

    $totalLen = ($parts | ForEach-Object { $_.Length } | Measure-Object -Sum).Sum
    $bodyBytes = [byte[]]::new($totalLen)
    $off = 0
    foreach ($p in $parts) { [System.Array]::Copy($p, 0, $bodyBytes, $off, $p.Length); $off += $p.Length }

    $headers = @{ 'X-SAP-LogonToken' = """$LogonToken"""; 'Accept' = 'application/json'; 'Content-Type' = "multipart/form-data; boundary=$boundary" }
    $resp = Invoke-RestMethod -Uri "$ServerUrl/biprws/promotion/" -Method Post -Body $bodyBytes -Headers $headers -TimeoutSec 600
    $jobId = if ($resp.id) { $resp.id } else { $resp.si_id }
    Write-Log "Import job created: ID=$jobId"
    return $jobId
}

function Wait-ForImport {
    param([string]$ServerUrl, [string]$LogonToken, [string]$JobId, [int]$TimeoutSeconds, [int]$PollInterval)
    Write-Log "Waiting for import job $JobId (timeout=${TimeoutSeconds}s)"
    $headers = @{ 'X-SAP-LogonToken' = """$LogonToken"""; 'Accept' = 'application/json' }
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $lastState = ""
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds $PollInterval
        $status = Invoke-RestMethod -Uri "$ServerUrl/biprws/promotion/$JobId" -Method Get -Headers $headers
        $state = $status.state
        if ($state -ne $lastState) { Write-Log "Import $JobId: $state"; $lastState = $state }
        if ($state -in @('Completed','Success')) { return $status }
        elseif ($state -in @('Failed','Error')) { throw "Import $JobId failed: $($status.errorMessage)" }
    }
    throw "Import $JobId timed out after ${TimeoutSeconds}s"
}

function Get-ImportResults {
    param([string]$ServerUrl, [string]$LogonToken, [string]$JobId)
    $headers = @{ 'X-SAP-LogonToken' = """$LogonToken"""; 'Accept' = 'application/json' }
    try { return Invoke-RestMethod -Uri "$ServerUrl/biprws/promotion/$JobId/results" -Method Get -Headers $headers }
    catch { Write-Log "Could not get import results: $_" -Level WARN; return $null }
}

function Close-RaylightSession {
    param([string]$ServerUrl, [string]$LogonToken)
    try { Invoke-RestMethod -Uri "$ServerUrl/biprws/logoff" -Method Post -Headers @{ 'X-SAP-LogonToken' = """$LogonToken""" } | Out-Null; Write-Log "Session closed" -Level DEBUG }
    catch { Write-Log "Session close failed: $_" -Level WARN }
}

# ── Main ────────────────────────────────────────────────────────────────────

try {
    Write-Log "================================================================"
    Write-Log "  BOBJ LCMBIAR Import via Raylight REST API"
    Write-Log "================================================================"
    Write-Log "Server: $ServerUrl | CMS: ${CmsServer}:${CmsPort}"
    Write-Log "LCMBIAR: $LcmbiarPath | Conflict: $ConflictResolution | OverwriteSec: $OverwriteSecurity"

    # Discover files
    if (Test-Path $LcmbiarPath -PathType Container) {
        $lcmbiarFiles = Get-ChildItem -Path $LcmbiarPath -Filter "*.lcmbiar" -Recurse
        if ($lcmbiarFiles.Count -eq 0) { $lcmbiarFiles = Get-ChildItem -Path $LcmbiarPath -Recurse -File | Where-Object { $_.Length -gt 0 } }
    } else { $lcmbiarFiles = @(Get-Item $LcmbiarPath) }

    if ($lcmbiarFiles.Count -eq 0) { Write-Log "No LCMBIAR files found" -Level ERROR; exit 1 }
    Write-Log "Found $($lcmbiarFiles.Count) LCMBIAR file(s)"

    # Checksum validation
    if ($ValidateChecksum -and $ExpectedChecksum) {
        foreach ($f in $lcmbiarFiles) {
            $hash = (Get-FileHash -Path $f.FullName -Algorithm SHA256).Hash
            if ($hash -ne $ExpectedChecksum) {
                Write-Log "Checksum mismatch: expected=$ExpectedChecksum actual=$hash" -Level ERROR
                Write-Host "##vso[task.logissue type=error]LCMBIAR checksum mismatch"; exit 1
            }
            Write-Log "Checksum verified: $($f.Name)"
        }
    }

    $logonToken = Get-RaylightSession -ServerUrl $ServerUrl -Username $Username -Password $Password -AuthType $AuthType
    $serverInfo = Test-RaylightHealth -ServerUrl $ServerUrl -LogonToken $logonToken

    $totalImported = 0; $totalSkipped = 0; $totalFailed = 0; $allSuccess = $true

    foreach ($file in $lcmbiarFiles) {
        Write-Log "Processing: $($file.FullName)"
        try {
            $jobId = Import-LcmbiarViaPromotion -ServerUrl $ServerUrl -LogonToken $logonToken `
                -LcmbiarFile $file.FullName -ConflictResolution $ConflictResolution `
                -OverwriteSecurity $OverwriteSecurity.IsPresent -TargetFolder $TargetFolder
            Wait-ForImport -ServerUrl $ServerUrl -LogonToken $logonToken -JobId $jobId `
                -TimeoutSeconds $JobTimeoutSeconds -PollInterval $PollIntervalSeconds | Out-Null
            $res = Get-ImportResults -ServerUrl $ServerUrl -LogonToken $logonToken -JobId $jobId
            $imp = if ($res) { $res.importedCount } else { 0 }
            $skip = if ($res) { $res.skippedCount } else { 0 }
            $fail = if ($res) { $res.failedCount } else { 0 }
            $totalImported += $imp; $totalSkipped += $skip; $totalFailed += $fail
            Write-Log "Result: imported=$imp skipped=$skip failed=$fail"
            if ($fail -gt 0) { $allSuccess = $false }
        }
        catch {
            Write-Log "Import failed for $($file.Name): $_" -Level ERROR
            $allSuccess = $false
        }
    }

    Close-RaylightSession -ServerUrl $ServerUrl -LogonToken $logonToken

    Write-Host "##vso[task.setvariable variable=importedCount]$totalImported"
    Write-Host "##vso[task.setvariable variable=skippedCount]$totalSkipped"
    Write-Host "##vso[task.setvariable variable=failedCount]$totalFailed"

    Write-Log "================================================================"
    Write-Log "  Summary: imported=$totalImported skipped=$totalSkipped failed=$totalFailed"
    Write-Log "================================================================"

    if ($allSuccess -and $totalFailed -eq 0) { exit 0 } else { exit 1 }
}
catch {
    Write-Log "FATAL: $_" -Level ERROR
    Write-Log $_.ScriptStackTrace -Level ERROR
    Write-Host "##vso[task.logissue type=error]Import failed: $_"
    exit 1
}
