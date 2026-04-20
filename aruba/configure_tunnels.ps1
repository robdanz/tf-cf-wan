<#
.SYNOPSIS
    Configure Cloudflare Magic WAN IPsec tunnels on Aruba EdgeConnect appliances.

.DESCRIPTION
    Reads tunnel data from 'terraform output' in the parent directory and pushes
    IPsec tunnel configuration to each EdgeConnect appliance via the ECOS REST API.

.PARAMETER Username
    EdgeConnect username. Default: admin

.PARAMETER Password
    EdgeConnect password. Prompted securely if omitted.

.PARAMETER Sites
    Comma-separated list of site names to process. Default: all sites.

.PARAMETER DryRun
    Print planned changes without making any API calls.

.PARAMETER VerifySSL
    Enforce TLS certificate verification. Default: skip verification (required for IP-based access with self-signed certs).

.EXAMPLE
    .\configure_tunnels.ps1 -DryRun
    .\configure_tunnels.ps1 -Sites "test-hq,test-branch01"
    .\configure_tunnels.ps1 -Username admin -VerifySSL   # only if appliance has a valid cert

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
        # PowerShell 6+ (Core): use -SkipCertificateCheck per-call (see Invoke-* calls below)
    } else {
        # PowerShell 5.1: set global callback
        Add-Type @"
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class TrustAllCerts : ICertificatePolicy {
    public bool CheckValidationResult(ServicePoint sp, X509Certificate cert,
        WebRequest req, int problem) { return true; }
}
"@
        [System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCerts
    }
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Write-Info  { param([string]$Msg) Write-Host "INFO  $Msg" }
function Write-Warn  { param([string]$Msg) Write-Host "WARN  $Msg" -ForegroundColor Yellow }
function Write-Err   { param([string]$Msg) Write-Host "ERROR $Msg" -ForegroundColor Red }

# ---------------------------------------------------------------------------
# EdgeConnect auth
#
# ECOS requires BOTH a session cookie AND an X-XSRF-TOKEN header on every
# call after login. Connect-EdgeConnect returns a hashtable:
#   @{ Session = <WebRequestSession>; CsrfToken = <string> }
# Pass this as $Auth to all subsequent helpers.
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
    if (-not $VerifySSL -and $PSVersionTable.PSVersion.Major -ge 6) {
        $params.SkipCertificateCheck = $true
    }
    try {
        Invoke-RestMethod @params | Out-Null
    } catch {
        throw "Login to $Host_ failed: $_"
    }
    $session = Get-Variable -Name session -ValueOnly
    # Extract CSRF token from the edgeosCsrfToken cookie set by login
    $csrfToken = $session.Cookies.GetCookies("https://$Host_") |
        Where-Object { $_.Name -eq "edgeosCsrfToken" } |
        Select-Object -First 1 -ExpandProperty Value
    if (-not $csrfToken) {
        throw "Login to $Host_ succeeded but edgeosCsrfToken cookie not found - cannot proceed"
    }
    return @{ Session = $session; CsrfToken = $csrfToken }
}

function Disconnect-EdgeConnect {
    param([string]$Host_, [hashtable]$Auth)
    try {
        $p = @{
            Method      = "DELETE"
            Uri         = "https://$Host_/rest/json/login"
            WebSession  = $Auth.Session
            Headers     = @{ "X-XSRF-TOKEN" = $Auth.CsrfToken }
            ErrorAction = "SilentlyContinue"
        }
        if (-not $VerifySSL -and $PSVersionTable.PSVersion.Major -ge 6) { $p.SkipCertificateCheck = $true }
        Invoke-RestMethod @p | Out-Null
    } catch { <# ignore logout errors #> }
}

# Wrapper: sends WebSession cookie + X-XSRF-TOKEN header on every call.
function Invoke-ECAPI {
    param(
        [string]    $Method,
        [string]    $Uri,
        [hashtable] $Auth,
        $Body = $null
    )
    $params = @{
        Method      = $Method
        Uri         = $Uri
        ContentType = "application/json"
        WebSession  = $Auth.Session
        Headers     = @{ "X-XSRF-TOKEN" = $Auth.CsrfToken }
        ErrorAction = "Stop"
    }
    # Use -InputObject (not pipeline) to preserve array type - piping unwraps single-element arrays
    if ($null -ne $Body) { $params.Body = (ConvertTo-Json -InputObject $Body -Depth 10 -Compress) }
    if (-not $VerifySSL -and $PSVersionTable.PSVersion.Major -ge 6) { $params.SkipCertificateCheck = $true }
    return Invoke-RestMethod @params
}

# ---------------------------------------------------------------------------
# Build tunnel config payload (single tunnel)
#
# Phase 1 (IKE):  AES-256, SHA-256, DH Group 14, IKEv2, aggressive mode
# Phase 2 (ESP):  AES-256 + AH SHA-256, PFS Group 14
# Mode:           ipsec_ip (passthrough IPsec - confirmed working on ECOS)
# Local identity: FQDN (fqdn_id from terraform output)
# ---------------------------------------------------------------------------
function Build-TunnelPayload {
    param($Tunnel, [string]$PSK)
    return @{
        $Tunnel.tunnel_name = @{
            admin        = "up"
            alias        = $Tunnel.tunnel_name
            auto_mtu     = $true
            gms_marked   = $false
            ipsec_enable     = $true
            ipsec_arc_window = "disable"
            presharedkey     = $PSK
            mode         = "ipsec_ip"
            nat_mode     = "none"
            peername     = "Cloudflare_IPSec"
            source       = if ($Tunnel.customer_endpoint) { $Tunnel.customer_endpoint } else { "0.0.0.0" }
            destination  = $Tunnel.cloudflare_endpoint
            max_bw_auto  = $true
            local_vrf    = 0
            ipsec        = @{
                ike_version    = 2
                ike_ealg       = "aes256"
                ike_aalg       = "sha256"
                ike_prf        = "auto"
                dhgroup        = "14"
                pfs            = $true
                pfsgroup       = "14"
                ipsec_suite_b  = "none"
                id_type        = "ufqdn"
                ike_id_local   = $Tunnel.fqdn_id
                ike_id_remote  = $Tunnel.cloudflare_endpoint
                exchange_mode  = "aggressive"
                mode           = "tunnel"
                esn            = $false
                dpd_delay      = 0
                dpd_retry      = 3
                ike_lifetime   = 0
                lifetime       = 240
                lifebytes      = 0
                security       = @{
                    ah  = @{ algorithm = "sha256" }
                    esp = @{ algorithm = "aes256" }
                }
            }
        }
    }
}

# ---------------------------------------------------------------------------
# Create a VTI on the appliance for one tunnel (idempotent)
# ---------------------------------------------------------------------------
function New-VTI {
    param([string]$ECHost, $Tunnel, [hashtable]$Auth)

    # GET existing VTIs - check idempotency and find next vtiN number
    $allVtis = $null
    try {
        $allVtis = Invoke-ECAPI -Method "GET" -Uri "https://$ECHost/rest/json/virtualif/vti" -Auth $Auth
    } catch {
        Write-Warn "    Could not read VTI list: $($_.Exception.Message)"
        return $false
    }

    # Check if a VTI already exists for this tunnel
    $existingKey = $allVtis.PSObject.Properties |
        Where-Object { $_.Value.tunnel -eq $Tunnel.tunnel_name } |
        Select-Object -First 1 -ExpandProperty Name
    if ($existingKey) {
        Write-Info "    VTI SKIP: already exists ($existingKey)"
        return $true
    }

    # Find next available vtiN number (start at 110)
    $nums = $allVtis.PSObject.Properties.Name |
        Where-Object { $_ -match '^vti(\d+)$' } |
        ForEach-Object { [int]($_ -replace '^vti', '') }
    $nextNum = if ($nums) { ($nums | Measure-Object -Maximum).Maximum + 1 } else { 110 }
    $vtiKey = "vti$nextNum"

    $prefixLen = [int]($Tunnel.interface_address -split '/')[1]
    $payload = @{
        admin           = $true
        auto_distribute = $true
        behindNAT       = "none"
        gms_marked      = $false
        ipaddr          = $Tunnel.cpe_inside_ip
        ipaddr_alias    = "0.0.0.0"
        label           = ""
        label_alias     = ""
        nmask           = $prefixLen
        nmask_alias     = 0
        role_id         = 0
        side            = "lan"
        tunnel          = $Tunnel.tunnel_name
        vrf_id          = 0
        zone            = 0
    }

    try {
        Invoke-ECAPI -Method "POST" -Uri "https://$ECHost/rest/json/virtualif/vti/$vtiKey" -Auth $Auth -Body $payload | Out-Null
        Write-Info "    VTI OK ($vtiKey)"
        return $true
    } catch {
        Write-Warn "    VTI FAILED: $($_.Exception.Message)"
        return $false
    }
}

# ---------------------------------------------------------------------------
# Configure one appliance
# ---------------------------------------------------------------------------
function Invoke-ConfigureSite {
    param([string]$ECHost, [string]$SiteName, [array]$SiteTunnels)

    Write-Host ""
    Write-Info "Site: $SiteName  appliance: $ECHost  tunnels: $($SiteTunnels.Count)"

    if ($DryRun) {
        foreach ($t in $SiteTunnels) {
            $local = if ($t.customer_endpoint) { $t.customer_endpoint } else { "(dynamic)" }
            Write-Info "  [DRY RUN] Would create tunnel: $($t.tunnel_name)  remote=$($t.cloudflare_endpoint)  local=$local"
            Write-Info "  [DRY RUN] Would create VTI: $($t.tunnel_name)  ip=$($t.cpe_inside_ip)/$([int]($t.interface_address -split '/')[1])"
        }
        return $true
    }

    try {
        Write-Host "  Logging in to $ECHost..." -NoNewline
        $auth = Connect-EdgeConnect -Host_ $ECHost -User $Username -Pass $Password
        Write-Host " OK"
    } catch {
        Write-Err "  $_"
        return $false
    }

    # Get existing tunnel aliases for idempotency
    $existingAliases = @()
    try {
        $existing = Invoke-ECAPI -Method "GET" -Uri "https://$ECHost/rest/json/thirdPartyTunnels/config" -Auth $auth
        $existingAliases = $existing.PSObject.Properties.Value | ForEach-Object { $_.alias }
    } catch {
        Write-Warn "  Could not read existing tunnels (will attempt to create anyway)"
    }

    $errors = 0
    foreach ($t in $SiteTunnels) {
        if ($existingAliases -contains $t.tunnel_name) {
            Write-Info "  SKIP tunnel: '$($t.tunnel_name)' already exists on appliance"
            # Still attempt VTI creation - it may have been missed previously
            if (-not (New-VTI -ECHost $ECHost -Tunnel $t -Auth $auth)) { $errors++ }
            continue
        }

        $payload = Build-TunnelPayload -Tunnel $t -PSK $script:PSK
        Write-Host "  Creating $($t.tunnel_name)..." -NoNewline
        try {
            Invoke-ECAPI -Method "POST" -Uri "https://$ECHost/rest/json/thirdPartyTunnels/config" -Auth $auth -Body $payload | Out-Null
            Write-Host " OK"
            if (-not (New-VTI -ECHost $ECHost -Tunnel $t -Auth $auth)) { $errors++ }
        } catch {
            Write-Host " FAILED"
            Write-Err "  $($_.Exception.Message)"
            $errors++
        }
    }

    Disconnect-EdgeConnect -Host_ $ECHost -Auth $auth
    return ($errors -eq 0)
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

# Check terraform is available
if (-not (Get-Command terraform -ErrorAction SilentlyContinue)) {
    Write-Err "terraform not found in PATH"
    exit 1
}

# Read terraform outputs
Push-Location $TFDir
try {
    Write-Info "Reading terraform outputs..."
    $tunnelDetailsRaw = terraform output -json tunnel_details 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $tunnelDetailsRaw) {
        Write-Err "Could not read terraform outputs. Run 'terraform apply' first."
        exit 1
    }
    $script:PSK = terraform output -raw tunnel_psk 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Err "Could not read tunnel_psk. Run 'terraform apply' first."
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

# Group tunnels by appliance
$byAppliance = $tunnelDetails.PSObject.Properties |
    Group-Object { $_.Value.ec_hostname } |
    Sort-Object Name

$siteNames = ($tunnelDetails.PSObject.Properties.Value | Select-Object -ExpandProperty site_name -Unique | Sort-Object) -join ", "
Write-Info "Sites to configure: $siteNames"

if ($DryRun) { Write-Info "--- DRY RUN (no changes will be made) ---" }

# Prompt for password (live run only)
if (-not $DryRun -and -not $Password) {
    $securePass = Read-Host "EdgeConnect password for $Username" -AsSecureString
    $Password   = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
                    [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePass))
}

$overallErrors = 0
foreach ($group in $byAppliance) {
    $ecHost    = $group.Name
    $siteName  = $group.Group[0].Value.site_name
    $tunnels   = $group.Group | ForEach-Object { $_.Value }
    if (-not (Invoke-ConfigureSite -ECHost $ecHost -SiteName $siteName -SiteTunnels $tunnels)) {
        $overallErrors++
    }
}

Write-Host ""
if ($overallErrors -eq 0) {
    Write-Info "All tunnels configured successfully."
} else {
    Write-Err "Completed with $overallErrors error(s)."
    exit 1
}
