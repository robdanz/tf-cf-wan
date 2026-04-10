<#
.SYNOPSIS
    Remove Cloudflare Magic WAN IPsec tunnels from Aruba EdgeConnect appliances.

.DESCRIPTION
    Backout script for configure_tunnels.ps1. Reads the same terraform output to
    identify which tunnels to remove. No separate state required — tunnel names
    are deterministic ({site_name}-pri and {site_name}-sec).

.PARAMETER Username
    EdgeConnect username. Default: admin

.PARAMETER Password
    EdgeConnect password. Prompted securely if omitted.

.PARAMETER Sites
    Comma-separated list of site names to process. Default: all sites.

.PARAMETER DryRun
    Print planned removals without making any API calls.

.PARAMETER VerifySSL
    Enforce TLS certificate verification. Default: skip verification (required for IP-based access with self-signed certs).

.EXAMPLE
    .\remove_tunnels.ps1 -DryRun
    .\remove_tunnels.ps1 -Sites "test-hq,test-branch01"
    .\remove_tunnels.ps1 -Username admin -VerifySSL   # only if appliance has a valid cert

.NOTES
    Requires: PowerShell 5.1+, terraform in PATH
#>
[CmdletBinding()]
param(
    [string]   $Username     = "admin",
    [string]   $Password     = "",
    [string]   $Sites        = "",
    [switch]   $DryRun,
    [switch]   $VerifySSL
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$TFDir     = Split-Path -Parent $ScriptDir

# ---------------------------------------------------------------------------
# TLS / SSL handling
# ---------------------------------------------------------------------------
if (-not $VerifySSL) {
    if ($PSVersionTable.PSVersion.Major -ge 6) {
        # PS 6+: use -SkipCertificateCheck per-call
    } else {
        Add-Type @"
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class TrustAllCerts2 : ICertificatePolicy {
    public bool CheckValidationResult(ServicePoint sp, X509Certificate cert,
        WebRequest req, int problem) { return true; }
}
"@
        [System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCerts2
    }
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Write-Info  { param([string]$Msg) Write-Host "INFO  $Msg" }
function Write-Warn  { param([string]$Msg) Write-Host "WARN  $Msg" -ForegroundColor Yellow }
function Write-Err   { param([string]$Msg) Write-Host "ERROR $Msg" -ForegroundColor Red }

function Invoke-EC {
    param([string]$Method, [string]$Uri, $Body = $null, $WebSession)
    $params = @{
        Method      = $Method
        Uri         = $Uri
        ContentType = "application/json"
        WebSession  = $WebSession
        ErrorAction = "Stop"
    }
    if ($null -ne $Body) { $params.Body = ($Body | ConvertTo-Json -Depth 5 -Compress) }
    if (-not $VerifySSL -and $PSVersionTable.PSVersion.Major -ge 6) { $params.SkipCertificateCheck = $true }
    return Invoke-RestMethod @params
}

# ---------------------------------------------------------------------------
# EdgeConnect auth
# ---------------------------------------------------------------------------
function Connect-EdgeConnect {
    param([string]$Host_, [string]$User, [string]$Pass)
    $params = @{
        Method          = "POST"
        Uri             = "https://$Host_/rest/json/login"
        ContentType     = "application/json"
        Body            = (@{ user = $User; password = $Pass } | ConvertTo-Json -Compress)
        SessionVariable = "session"
        ErrorAction     = "Stop"
    }
    if (-not $VerifySSL -and $PSVersionTable.PSVersion.Major -ge 6) { $params.SkipCertificateCheck = $true }
    try {
        Invoke-RestMethod @params | Out-Null
    } catch {
        throw "Login to $Host_ failed: $_"
    }
    return (Get-Variable -Name session -ValueOnly)
}

function Disconnect-EdgeConnect {
    param([string]$Host_, $WebSession)
    try {
        $p = @{ Method = "DELETE"; Uri = "https://$Host_/rest/json/login"; WebSession = $WebSession; ErrorAction = "SilentlyContinue" }
        if (-not $VerifySSL -and $PSVersionTable.PSVersion.Major -ge 6) { $p.SkipCertificateCheck = $true }
        Invoke-RestMethod @p | Out-Null
    } catch { <# ignore logout errors #> }
}

# ---------------------------------------------------------------------------
# Remove tunnels for one appliance
# ---------------------------------------------------------------------------
function Invoke-RemoveSite {
    param([string]$ECHost, [string]$SiteName, [array]$SiteTunnels)

    $expectedNames = $SiteTunnels | ForEach-Object { $_.tunnel_name }

    Write-Host ""
    Write-Info "Site: $SiteName  appliance: $ECHost"

    if ($DryRun) {
        foreach ($name in $expectedNames) {
            Write-Info "  [DRY RUN] Would remove tunnel: $name"
            Write-Info "  [DRY RUN] Would remove VTI for: $name"
        }
        return $true
    }

    try {
        Write-Host "  Logging in to $ECHost..." -NoNewline
        $webSession = Connect-EdgeConnect -Host_ $ECHost -User $Username -Pass $Password
        Write-Host " OK"
    } catch {
        Write-Err "  $_"
        return $false
    }

    # Get all existing tunnels: map alias -> tunnel id
    $allTunnels = $null
    try {
        $allTunnels = Invoke-EC -Method "GET" -Uri "https://$ECHost/rest/json/thirdPartyTunnels/config" -WebSession $webSession
    } catch {
        Write-Err "  Could not read tunnel list from $ECHost : $($_.Exception.Message)"
        Disconnect-EdgeConnect -Host_ $ECHost -WebSession $webSession
        return $false
    }

    # Find tunnel IDs matching our expected aliases
    $idsToDelete = @()
    foreach ($name in $expectedNames) {
        $match = $allTunnels.PSObject.Properties | Where-Object { $_.Value.alias -eq $name }
        if ($match) {
            Write-Info "  Found '$name' as $($match.Name) — queued for deletion"
            $idsToDelete += $match.Name
        } else {
            Write-Warn "  Tunnel '$name' not found on appliance — skipping"
        }
    }

    if ($idsToDelete.Count -eq 0) {
        Write-Info "  No tunnels to remove on $ECHost"
        Disconnect-EdgeConnect -Host_ $ECHost -WebSession $webSession
        return $true
    }

    Write-Host "  Removing $($idsToDelete.Count) tunnel(s)..." -NoNewline
    try {
        Invoke-EC -Method "POST" -Uri "https://$ECHost/rest/json/thirdPartyTunnels/deleteMultiple" `
            -Body $idsToDelete -WebSession $webSession | Out-Null
        Write-Host " OK"
    } catch {
        Write-Host " FAILED"
        Write-Err "  $($_.Exception.Message)"
        Disconnect-EdgeConnect -Host_ $ECHost -WebSession $webSession
        return $false
    }

    # Remove VTIs associated with our tunnels
    $vtiErrors = 0
    $allVtis = $null
    try {
        $p = @{ Method = "GET"; Uri = "https://$ECHost/rest/json/virtualif/vti"; WebSession = $webSession; ErrorAction = "Stop" }
        if (-not $VerifySSL -and $PSVersionTable.PSVersion.Major -ge 6) { $p.SkipCertificateCheck = $true }
        $allVtis = Invoke-RestMethod @p
    } catch {
        Write-Warn "  Could not read VTI list: $($_.Exception.Message)"
    }

    if ($allVtis) {
        foreach ($name in $expectedNames) {
            $vtiEntry = $allVtis.PSObject.Properties |
                Where-Object { $_.Value.tunnel -eq $name } |
                Select-Object -First 1
            if (-not $vtiEntry) {
                Write-Info "  No VTI found for '$name' — skipping"
                continue
            }
            $vtiKey = $vtiEntry.Name
            Write-Host "  Removing VTI $vtiKey (tunnel: $name)..." -NoNewline
            try {
                $p = @{
                    Method      = "DELETE"
                    Uri         = "https://$ECHost/rest/json/virtualif/vti/$vtiKey"
                    WebSession  = $webSession
                    ErrorAction = "Stop"
                }
                if (-not $VerifySSL -and $PSVersionTable.PSVersion.Major -ge 6) { $p.SkipCertificateCheck = $true }
                Invoke-RestMethod @p | Out-Null
                Write-Host " OK"
            } catch {
                Write-Host " FAILED"
                Write-Err "  $($_.Exception.Message)"
                $vtiErrors++
            }
        }
    }

    Disconnect-EdgeConnect -Host_ $ECHost -WebSession $webSession
    return ($vtiErrors -eq 0)
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
if (-not (Get-Command terraform -ErrorAction SilentlyContinue)) {
    Write-Err "terraform not found in PATH"
    exit 1
}

Push-Location $TFDir
try {
    Write-Info "Reading terraform outputs..."
    $tunnelDetailsRaw = terraform output -json tunnel_details 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $tunnelDetailsRaw) {
        Write-Err "Could not read terraform outputs. Run 'terraform apply' first."
        exit 1
    }
} finally {
    Pop-Location
}

$tunnelDetails = $tunnelDetailsRaw | ConvertFrom-Json

# Filter by --Sites
if ($Sites) {
    $siteFilter = $Sites -split "," | ForEach-Object { $_.Trim() }
    $filtered = [PSCustomObject]@{}
    $tunnelDetails.PSObject.Properties | Where-Object { $_.Value.site_name -in $siteFilter } |
        ForEach-Object { $filtered | Add-Member -NotePropertyName $_.Name -NotePropertyValue $_.Value }
    $tunnelDetails = $filtered
    if ($tunnelDetails.PSObject.Properties.Count -eq 0) {
        Write-Err "No tunnels matched --Sites '$Sites'"
        exit 1
    }
}

# Group by appliance
$byAppliance = $tunnelDetails.PSObject.Properties |
    Group-Object { $_.Value.ec_hostname } |
    Sort-Object Name

$siteNames = ($tunnelDetails.PSObject.Properties.Value | Select-Object -ExpandProperty site_name -Unique | Sort-Object) -join ", "
Write-Info "Sites to remove tunnels from: $siteNames"

if ($DryRun) { Write-Info "--- DRY RUN (no changes will be made) ---" }

if (-not $DryRun -and -not $Password) {
    $securePass = Read-Host "EdgeConnect password for $Username" -AsSecureString
    $Password   = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
                    [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePass))
}

$overallErrors = 0
foreach ($group in $byAppliance) {
    $ecHost   = $group.Name
    $siteName = $group.Group[0].Value.site_name
    $tunnels  = $group.Group | ForEach-Object { $_.Value }
    if (-not (Invoke-RemoveSite -ECHost $ecHost -SiteName $siteName -SiteTunnels $tunnels)) {
        $overallErrors++
    }
}

Write-Host ""
if ($overallErrors -eq 0) {
    Write-Info "All tunnels removed successfully."
} else {
    Write-Err "Completed with $overallErrors error(s)."
    exit 1
}
