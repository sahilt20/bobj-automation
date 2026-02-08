<#
.SYNOPSIS
    Validates LCMBIAR packages and verifies deployments via Raylight REST API.

.DESCRIPTION
    Two modes:
    1. Package Validation: structure, checksums, manifest, content integrity
    2. Deployment Verification: Raylight /about + InfoStore health checks
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)][string]$ServerUrl,
    [Parameter(Mandatory=$false)][string]$CmsServer,
    [Parameter(Mandatory=$false)][string]$Username,
    [Parameter(Mandatory=$false)][string]$Password,
    [Parameter(Mandatory=$false)][ValidateSet('secEnterprise','secLDAP','secWinAD','secSAPR3')][string]$AuthType = 'secEnterprise',
    [Parameter(Mandatory=$false)][string]$LcmbiarPath,
    [Parameter(Mandatory=$false)][string]$ExpectedChecksum,
    [Parameter(Mandatory=$false)][switch]$VerifyDeployment,
    [Parameter(Mandatory=$false)][string]$OutputPath
)

$ErrorActionPreference = 'Stop'

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    switch ($Level) {
        'ERROR' { Write-Host "[$ts] [$Level] $Message" -ForegroundColor Red }
        'WARN'  { Write-Host "[$ts] [$Level] $Message" -ForegroundColor Yellow }
        'OK'    { Write-Host "[$ts] [$Level] $Message" -ForegroundColor Green }
        default { Write-Host "[$ts] [$Level] $Message" }
    }
}

function Test-LcmbiarPackage {
    param([string]$Path, [string]$ExpectedHash)
    $report = @{ valid=$true; objectCount=0; totalSizeBytes=0; warnings=@(); errors=@(); objects=@(); manifestFound=$false; checksumValid=$null; sha256=$null }

    if (Test-Path $Path -PathType Container) {
        $files = Get-ChildItem -Path $Path -Recurse -File
        $report.objectCount = $files.Count
        $report.totalSizeBytes = ($files | Measure-Object -Property Length -Sum).Sum
        if ($report.objectCount -eq 0) { $report.errors += "No files found"; $report.valid = $false; return $report }

        $manifest = $files | Where-Object { $_.Name -like '*manifest*' -or $_.Name -like '*.xml' }
        $report.manifestFound = [bool]$manifest

        $lcm = $files | Where-Object { $_.Extension -eq '.lcmbiar' }
        foreach ($f in $lcm) {
            $hash = (Get-FileHash -Path $f.FullName -Algorithm SHA256).Hash
            $report.objects += @{ name=$f.Name; size=$f.Length; sha256=$hash }
            $report.sha256 = $hash
            if ($ExpectedHash -and $hash -ne $ExpectedHash) {
                $report.errors += "Checksum mismatch for $($f.Name)"
                $report.checksumValid = $false; $report.valid = $false
            } elseif ($ExpectedHash) { $report.checksumValid = $true }
        }

        $empty = $files | Where-Object { $_.Length -eq 0 }
        if ($empty.Count -gt 0) { $report.warnings += "$($empty.Count) empty file(s)" }
    }
    else {
        $file = Get-Item $Path
        if ($file.Length -eq 0) { $report.errors += "File is empty"; $report.valid = $false; return $report }
        $hash = (Get-FileHash -Path $Path -Algorithm SHA256).Hash
        $report.objectCount = 1; $report.totalSizeBytes = $file.Length; $report.sha256 = $hash
        $report.objects += @{ name=$file.Name; size=$file.Length; sha256=$hash }
        if ($ExpectedHash) {
            if ($hash -ne $ExpectedHash) { $report.errors += "Checksum mismatch"; $report.checksumValid = $false; $report.valid = $false }
            else { $report.checksumValid = $true }
        }
    }
    return $report
}

function Test-RaylightDeployment {
    param([string]$ServerUrl, [string]$Username, [string]$Password, [string]$AuthType)
    $report = @{ verified=$false; serverAccessible=$false; authenticated=$false; raylightHealthy=$false; infostoreOk=$false; serverVersion=$null; errors=@() }

    try {
        $resp = Invoke-WebRequest -Uri "$ServerUrl/biprws" -Method Get -UseBasicParsing -TimeoutSec 30
        $report.serverAccessible = ($resp.StatusCode -eq 200)
    }
    catch { $report.errors += "Server unreachable: $($_.Exception.Message)"; return $report }

    try {
        $body = @{ userName=$Username; password=$Password; auth=$AuthType } | ConvertTo-Json
        $auth = Invoke-RestMethod -Uri "$ServerUrl/biprws/logon/long" -Method Post -Body $body -ContentType 'application/json' -TimeoutSec 60
        $logonToken = $auth.logonToken
        if ($logonToken) { $report.authenticated = $true } else { $report.errors += "No logon token"; return $report }
    }
    catch { $report.errors += "Auth failed: $($_.Exception.Message)"; return $report }

    $headers = @{ 'X-SAP-LogonToken' = """$logonToken"""; 'Accept' = 'application/json' }

    try {
        $about = Invoke-RestMethod -Uri "$ServerUrl/biprws/raylight/v1/about" -Method Get -Headers $headers -TimeoutSec 30
        $report.raylightHealthy = $true
        $report.serverVersion = "$($about.productName) v$($about.productVersion)"
    }
    catch { $report.errors += "Raylight unhealthy: $($_.Exception.Message)" }

    try {
        Invoke-RestMethod -Uri "$ServerUrl/biprws/infostore" -Method Get -Headers $headers -TimeoutSec 30 | Out-Null
        $report.infostoreOk = $true
    }
    catch { $report.errors += "InfoStore error: $($_.Exception.Message)" }

    try { Invoke-RestMethod -Uri "$ServerUrl/biprws/logoff" -Method Post -Headers $headers | Out-Null } catch { }

    $report.verified = $report.serverAccessible -and $report.authenticated -and $report.raylightHealthy
    return $report
}

# ── Main ────────────────────────────────────────────────────────────────────

try {
    Write-Log "================================================================"
    Write-Log "  LCMBIAR Validation / Deployment Verification"
    Write-Log "================================================================"

    if ($VerifyDeployment) {
        if (-not $ServerUrl -or -not $Username -or -not $Password) { Write-Log "ServerUrl/Username/Password required" -Level ERROR; exit 1 }
        $report = Test-RaylightDeployment -ServerUrl $ServerUrl -Username $Username -Password $Password -AuthType $AuthType

        if ($OutputPath) {
            $dir = Split-Path $OutputPath -Parent
            if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
            $report | ConvertTo-Json -Depth 5 | Out-File $OutputPath -Encoding UTF8
        }

        Write-Host "##vso[task.setvariable variable=deploymentVerified]$($report.verified)"
        if ($report.verified) { Write-Log "Deployment Verification PASSED" -Level OK; exit 0 }
        else { foreach ($e in $report.errors) { Write-Log $e -Level ERROR }; Write-Log "Deployment Verification FAILED" -Level ERROR; exit 1 }
    }
    else {
        if (-not $LcmbiarPath -or -not (Test-Path $LcmbiarPath)) { Write-Log "Valid LcmbiarPath required" -Level ERROR; exit 1 }
        $report = Test-LcmbiarPackage -Path $LcmbiarPath -ExpectedHash $ExpectedChecksum

        Write-Log "Objects: $($report.objectCount) | Size: $([math]::Round($report.totalSizeBytes/1MB,2))MB | Valid: $($report.valid)"
        foreach ($w in $report.warnings) { Write-Log "Warning: $w" -Level WARN }
        foreach ($e in $report.errors) { Write-Log "Error: $e" -Level ERROR }

        if ($OutputPath) {
            $dir = Split-Path $OutputPath -Parent
            if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
            $report | ConvertTo-Json -Depth 5 | Out-File $OutputPath -Encoding UTF8
        }

        Write-Host "##vso[task.setvariable variable=validationPassed]$($report.valid)"
        Write-Host "##vso[task.setvariable variable=objectCount]$($report.objectCount)"
        if ($report.sha256) { Write-Host "##vso[task.setvariable variable=lcmbiarSHA256]$($report.sha256)" }

        if ($report.valid) { Write-Log "Validation PASSED" -Level OK; exit 0 }
        else { Write-Log "Validation FAILED" -Level ERROR; exit 1 }
    }
}
catch {
    Write-Log "Error: $_" -Level ERROR
    exit 1
}
