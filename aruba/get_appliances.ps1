<#
.SYNOPSIS
    Query Aruba Orchestrator and generate a proposed sites.csv.

.DESCRIPTION
    Pulls all approved appliances from Orchestrator, queries each appliance's
    interface state to extract WAN public IP (customer_gw_ip) and LAN subnets,
    then writes sites.csv.proposed for review.

    IMPORTANT: Always writes to sites.csv.proposed, never sites.csv directly.
    Review the output, edit as needed, then rename or merge into sites.csv.

.PARAMETER Orchestrator
    Orchestrator hostname or IP (required).

.PARAMETER Token
    Orchestrator API token. If omitted, uses the ARUBA_API_TOKEN environment variable.

.PARAMETER Output
    Output file path. Default: ..\sites.csv.proposed
    Use "-Output -" to print to stdout.

.PARAMETER VerifySSL
    Enforce TLS certificate verification. Default: skip verification (required for IP-based access with self-signed certs).

.EXAMPLE
    .\get_appliances.ps1 -Orchestrator 10.0.0.1
    .\get_appliances.ps1 -Orchestrator 10.0.0.1 -Token "mytoken"
    .\get_appliances.ps1 -Orchestrator 10.0.0.1 -Output "-"
    .\get_appliances.ps1 -Orchestrator 10.0.0.1 -VerifySSL

.NOTES
    Requires: PowerShell 5.1+

    Output columns:
      site_name      Appliance hostname (lowercased, non-alphanumeric -> hyphen)
      site_index     Auto-assigned 0-based index (sorted alphabetically)
      customer_gw_ip First active WAN interface publicIp (blank = NAT/dynamic)
      lan_subnets    Comma-separated LAN network CIDRs
      ec_hostname    Appliance management IP (replace with DNS name if preferred)

    Next steps after running:
      1. Review sites.csv.proposed
      2. Verify/correct customer_gw_ip for each site
      3. Remove any management or transit subnets from lan_subnets
      4. Replace ec_hostname IPs with DNS names if preferred
      5. Copy to sites.csv, then run: terraform plan
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $Orchestrator,
    [string]  $Token       = "",
    [string]  $Output      = "",
    [switch]  $VerifySSL
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$TFDir     = Split-Path -Parent $ScriptDir

if (-not $Output) { $Output = Join-Path $TFDir "sites.csv.proposed" }

# Resolve token from parameter or environment variable
if (-not $Token) { $Token = $env:ARUBA_API_TOKEN }
if (-not $Token) {
    Write-Error "API token required: use -Token or set the ARUBA_API_TOKEN environment variable."
    exit 1
}

# ---------------------------------------------------------------------------
# TLS / SSL handling
# ---------------------------------------------------------------------------
if (-not $VerifySSL) {
    if ($PSVersionTable.PSVersion.Major -ge 6) {
        # PS 6+: -SkipCertificateCheck used per-call
    } else {
        Add-Type @"
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class TrustAllCerts3 : ICertificatePolicy {
    public bool CheckValidationResult(ServicePoint sp, X509Certificate cert,
        WebRequest req, int problem) { return true; }
}
"@
        [System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCerts3
    }
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Write-Info { param([string]$Msg) Write-Host "INFO  $Msg" -ForegroundColor Cyan }
function Write-Warn { param([string]$Msg) Write-Host "WARN  $Msg" -ForegroundColor Yellow }
function Write-Err  { param([string]$Msg) Write-Host "ERROR $Msg" -ForegroundColor Red }

function Invoke-Orch {
    param([string]$Path)
    $params = @{
        Method      = "GET"
        Uri         = "https://$Orchestrator/gms/rest/$Path"
        Headers     = @{ "X-Auth-Token" = $Token; "Accept" = "application/json" }
        ErrorAction = "Stop"
    }
    if (-not $VerifySSL -and $PSVersionTable.PSVersion.Major -ge 6) { $params.SkipCertificateCheck = $true }
    return Invoke-RestMethod @params
}

# ---------------------------------------------------------------------------
# Subnet helpers
# ---------------------------------------------------------------------------
function ConvertTo-PrefixLength {
    param([string]$Mask)
    $bits = 0
    foreach ($octet in ($Mask -split '\.')) {
        $val = [int]$octet
        while ($val -gt 0) { $bits += $val -band 1; $val = $val -shr 1 }
    }
    return $bits
}

function Get-NetworkCidr {
    param([string]$IP, [string]$Mask)
    $ipOcts   = $IP   -split '\.' | ForEach-Object { [int]$_ }
    $maskOcts = $Mask -split '\.' | ForEach-Object { [int]$_ }
    $net = for ($i = 0; $i -lt 4; $i++) { $ipOcts[$i] -band $maskOcts[$i] }
    $prefix = ConvertTo-PrefixLength $Mask
    return "$($net -join '.')/$prefix"
}

# ---------------------------------------------------------------------------
# Process one appliance — returns a CSV row hashtable
# ---------------------------------------------------------------------------
function Get-ApplianceCsvRow {
    param([string]$NePk, [string]$HostName, [string]$MgmtIP, [int]$Index)

    # Sanitize hostname to site_name: lowercase, non-alphanumeric chars -> hyphen, trim hyphens
    $siteName = $HostName.ToLower() -replace '[^a-z0-9]+', '-' -replace '^-|-$', ''

    # Query interface state
    $ifaceData = $null
    try {
        $ifaceData = Invoke-Orch "interfaceState?nePk=$NePk&cached=true"
    } catch {
        Write-Warn "Could not get interface state for $HostName ($NePk) — using empty values"
    }

    if (-not $ifaceData) {
        return [PSCustomObject]@{
            site_name      = $siteName
            site_index     = $Index
            customer_gw_ip = ""
            lan_subnets    = ""
            ec_hostname    = $MgmtIP
        }
    }

    # WAN: first active WAN interface, sorted by name, prefer publicIp over ipv4
    $wanIp = ""
    $wanIfs = $ifaceData.ifInfo |
        Where-Object { $_.'wan-if' -eq $true -and $_.oper -eq $true } |
        Sort-Object ifname
    if ($wanIfs) {
        $first  = @($wanIfs)[0]
        $wanIp  = if ($first.publicIp)  { $first.publicIp }
                  elseif ($first.ipv4)  { $first.ipv4 }
                  else                  { "" }
    }

    # LAN: all active LAN interfaces with valid IPs → compute network/prefix
    $lanCidrs = @()
    $lanIfs = $ifaceData.ifInfo |
        Where-Object { $_.'lan-if' -eq $true -and $_.oper -eq $true -and $_.ipv4 }
    foreach ($iface in $lanIfs) {
        $mask = if ($iface.ipv4mask) { $iface.ipv4mask } else { "255.255.255.0" }
        try {
            $lanCidrs += Get-NetworkCidr -IP $iface.ipv4 -Mask $mask
        } catch {
            Write-Warn "  Could not compute CIDR for $($iface.ifname) on $HostName — skipping"
        }
    }
    $lanSubnets = $lanCidrs -join ","

    return [PSCustomObject]@{
        site_name      = $siteName
        site_index     = $Index
        customer_gw_ip = $wanIp
        lan_subnets    = $lanSubnets
        ec_hostname    = $MgmtIP
    }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
Write-Info "Fetching appliance list from $Orchestrator..."
$appliances = Invoke-Orch "appliance"
Write-Info "Found $($appliances.Count) appliance(s)"

if ($appliances.Count -eq 0) {
    Write-Err "No appliances returned. Check Orchestrator connectivity and token."
    exit 1
}

# Sort alphabetically by sanitized site_name for stable index assignment
$sorted = $appliances | Sort-Object {
    $_.hostName.ToLower() -replace '[^a-z0-9]+', '-' -replace '^-|-$', ''
}

# Build CSV rows
$rows = @()
$index = 0
foreach ($appliance in $sorted) {
    Write-Info "  Processing $($appliance.hostName) ($($appliance.id))..."
    $row = Get-ApplianceCsvRow -NePk $appliance.id -HostName $appliance.hostName `
                               -MgmtIP $appliance.IP -Index $index
    $rows += $row
    $index++
}

# ---------------------------------------------------------------------------
# Render CSV
# ---------------------------------------------------------------------------
$csvLines = @("site_name,site_index,customer_gw_ip,lan_subnets,ec_hostname")
foreach ($row in $rows) {
    # Quote lan_subnets field if it contains commas
    $lan = if ($row.lan_subnets -match ",") { "`"$($row.lan_subnets)`"" } else { $row.lan_subnets }
    $csvLines += "$($row.site_name),$($row.site_index),$($row.customer_gw_ip),$lan,$($row.ec_hostname)"
}
$csvContent = $csvLines -join "`n"

if ($Output -eq "-") {
    Write-Output $csvContent
} else {
    $csvContent | Set-Content -Path $Output -Encoding UTF8
    Write-Info ""
    Write-Info "Written to: $Output"
    Write-Info ""
    Write-Info "Next steps:"
    Write-Info "  1. Review $Output"
    Write-Info "  2. Verify customer_gw_ip — blank means NAT/dynamic"
    Write-Info "  3. Remove management/transit subnets from lan_subnets"
    Write-Info "  4. Replace ec_hostname IPs with DNS names if preferred"
    Write-Info "  5. Copy to sites.csv:  Copy-Item $Output $(Join-Path $TFDir 'sites.csv')"
    Write-Info "  6. Run: terraform plan"
}
