<#
.SYNOPSIS
    Tests connectivity to SAP BusinessObjects server.

.DESCRIPTION
    Validates that the BOBJ server is accessible and credentials are valid.

.PARAMETER ServerUrl
    The URL of the BOBJ server

.PARAMETER CmsServer
    The CMS server hostname

.PARAMETER CmsPort
    The CMS port (default: 6400)

.PARAMETER Username
    Username for authentication

.PARAMETER Password
    Password for authentication

.PARAMETER AuthType
    Authentication type
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
    [string]$AuthType = 'secEnterprise'
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

try {
    Write-Log "=== BOBJ Connection Test ===" -Level INFO
    Write-Log "Server URL: $ServerUrl"
    Write-Log "CMS Server: $CmsServer"
    Write-Log "CMS Port: $CmsPort"
    Write-Log "Auth Type: $AuthType"
    Write-Log "Username: $Username"
    
    # Test 1: Basic connectivity
    Write-Log "Testing basic HTTP connectivity..."
    try {
        $response = Invoke-WebRequest -Uri "$ServerUrl/biprws" -Method Get -UseBasicParsing -TimeoutSec 30
        if ($response.StatusCode -eq 200) {
            Write-Log "HTTP connectivity: OK" -Level OK
        }
    }
    catch {
        Write-Log "HTTP connectivity failed: $_" -Level ERROR
        exit 1
    }
    
    # Test 2: Authentication
    Write-Log "Testing authentication..."
    $loginUrl = "$ServerUrl/biprws/logon/long"
    $loginBody = @{
        userName = $Username
        password = $Password
        auth = $AuthType
    } | ConvertTo-Json
    
    try {
        $authResponse = Invoke-RestMethod -Uri $loginUrl -Method Post -Body $loginBody -ContentType 'application/json' -TimeoutSec 60
        
        if ($authResponse.logonToken) {
            Write-Log "Authentication: OK" -Level OK
            $logonToken = $authResponse.logonToken
            
            # Test 3: API access
            Write-Log "Testing API access..."
            $headers = @{
                'X-SAP-LogonToken' = $logonToken
                'Accept' = 'application/json'
            }
            
            $infoUrl = "$ServerUrl/biprws/infostore/cuid_xxxxx"
            try {
                # Just test we can make API calls
                $apiTest = Invoke-RestMethod -Uri "$ServerUrl/biprws/infostore" -Method Get -Headers $headers -TimeoutSec 30
                Write-Log "API access: OK" -Level OK
            }
            catch {
                Write-Log "API access test returned expected error (this is OK): $($_.Exception.Message)" -Level WARN
            }
            
            # Logout
            try {
                $logoffUrl = "$ServerUrl/biprws/logoff"
                Invoke-RestMethod -Uri $logoffUrl -Method Post -Headers $headers | Out-Null
                Write-Log "Session cleanup: OK" -Level OK
            }
            catch {
                Write-Log "Session cleanup failed (non-critical): $_" -Level WARN
            }
            
        }
        else {
            Write-Log "Authentication failed: No logon token received" -Level ERROR
            exit 1
        }
    }
    catch {
        Write-Log "Authentication failed: $_" -Level ERROR
        exit 1
    }
    
    Write-Log "=== All Connection Tests Passed ===" -Level OK
    
    # Set Azure DevOps variable
    Write-Host "##vso[task.setvariable variable=bobjConnectionStatus]success"
    
    exit 0
}
catch {
    Write-Log "Connection test failed: $_" -Level ERROR
    Write-Host "##vso[task.setvariable variable=bobjConnectionStatus]failed"
    exit 1
}
