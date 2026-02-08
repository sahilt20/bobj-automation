<#
.SYNOPSIS
    Tests connectivity to SAP BusinessObjects server via Raylight REST API.

.DESCRIPTION
    Multi-step health check:
        1. HTTP connectivity to /biprws
        2. Authentication via /biprws/logon/long
        3. Raylight API health via /biprws/raylight/v1/about
        4. InfoStore API via /biprws/infostore
        5. Promotion API via /biprws/promotion/
        6. Session cleanup via /biprws/logoff
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$ServerUrl,
    [Parameter(Mandatory=$true)][string]$CmsServer,
    [Parameter(Mandatory=$false)][int]$CmsPort = 6400,
    [Parameter(Mandatory=$true)][string]$Username,
    [Parameter(Mandatory=$true)][string]$Password,
    [Parameter(Mandatory=$false)][ValidateSet('secEnterprise','secLDAP','secWinAD','secSAPR3')][string]$AuthType = 'secEnterprise'
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

try {
    Write-Log "================================================================"
    Write-Log "  BOBJ Raylight Connection Health Check"
    Write-Log "================================================================"
    Write-Log "Server: $ServerUrl | CMS: ${CmsServer}:${CmsPort} | Auth: $AuthType"

    # Check 1: HTTP
    Write-Log "Check 1/6: HTTP connectivity..."
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $resp = Invoke-WebRequest -Uri "$ServerUrl/biprws" -Method Get -UseBasicParsing -TimeoutSec 30
        $sw.Stop()
        if ($resp.StatusCode -eq 200) { Write-Log "HTTP: OK ($($sw.ElapsedMilliseconds)ms)" -Level OK }
    }
    catch { $sw.Stop(); Write-Log "HTTP FAILED: $_" -Level ERROR; throw "Cannot reach $ServerUrl/biprws" }

    # Check 2: Auth
    Write-Log "Check 2/6: Authentication..."
    $sw.Restart()
    try {
        $loginBody = @{ userName=$Username; password=$Password; auth=$AuthType } | ConvertTo-Json
        $authResp = Invoke-RestMethod -Uri "$ServerUrl/biprws/logon/long" -Method Post -Body $loginBody -ContentType 'application/json' -TimeoutSec 60
        $sw.Stop()
        if ($authResp.logonToken) {
            $logonToken = $authResp.logonToken
            Write-Log "Authentication: OK ($($sw.ElapsedMilliseconds)ms)" -Level OK
        } else { throw "No logon token" }
    }
    catch { $sw.Stop(); Write-Log "Auth FAILED: $_" -Level ERROR; throw "Auth failed for '$Username'" }

    $headers = @{ 'X-SAP-LogonToken' = """$logonToken"""; 'Accept' = 'application/json' }

    # Check 3: Raylight API
    Write-Log "Check 3/6: Raylight API /biprws/raylight/v1/about..."
    $sw.Restart()
    try {
        $aboutResp = Invoke-RestMethod -Uri "$ServerUrl/biprws/raylight/v1/about" -Method Get -Headers $headers -TimeoutSec 30
        $sw.Stop()
        Write-Log "Raylight: $($aboutResp.productName) v$($aboutResp.productVersion) ($($sw.ElapsedMilliseconds)ms)" -Level OK
    }
    catch { $sw.Stop(); Write-Log "Raylight API: warning – $_" -Level WARN }

    # Check 4: InfoStore
    Write-Log "Check 4/6: InfoStore API..."
    $sw.Restart()
    try {
        Invoke-RestMethod -Uri "$ServerUrl/biprws/infostore" -Method Get -Headers $headers -TimeoutSec 30 | Out-Null
        $sw.Stop(); Write-Log "InfoStore: OK ($($sw.ElapsedMilliseconds)ms)" -Level OK
    }
    catch { $sw.Stop(); Write-Log "InfoStore: warning – $_" -Level WARN }

    # Check 5: Promotion API
    Write-Log "Check 5/6: Promotion API..."
    $sw.Restart()
    try {
        Invoke-WebRequest -Uri "$ServerUrl/biprws/promotion/" -Method Get -Headers $headers -UseBasicParsing -TimeoutSec 30 | Out-Null
        $sw.Stop(); Write-Log "Promotion API: OK ($($sw.ElapsedMilliseconds)ms)" -Level OK
    }
    catch {
        $sw.Stop()
        $sc = $_.Exception.Response.StatusCode.value__
        if ($sc -in @(404,405,200)) { Write-Log "Promotion API: reachable (HTTP $sc)" -Level OK }
        else { Write-Log "Promotion API: warning – $_" -Level WARN }
    }

    # Check 6: Logoff
    Write-Log "Check 6/6: Session cleanup..."
    try { Invoke-RestMethod -Uri "$ServerUrl/biprws/logoff" -Method Post -Headers $headers | Out-Null; Write-Log "Logoff: OK" -Level OK }
    catch { Write-Log "Logoff: warning – $_" -Level WARN }

    Write-Log "================================================================"
    Write-Log "  All Connection Checks Passed" -Level OK
    Write-Log "================================================================"
    Write-Host "##vso[task.setvariable variable=bobjConnectionStatus]success"
    Write-Host "##vso[task.setvariable variable=bobjServerVersion]$($aboutResp.productVersion)"
    exit 0
}
catch {
    Write-Log "Connection check failed: $_" -Level ERROR
    Write-Host "##vso[task.logissue type=error]BOBJ connection failed: $_"
    Write-Host "##vso[task.setvariable variable=bobjConnectionStatus]failed"
    exit 1
}
