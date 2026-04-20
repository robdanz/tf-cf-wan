<#
.SYNOPSIS
    Query Aruba Orchestrator to gather per-site details and generate sites.csv.proposed.

.DESCRIPTION
    Connects to the Aruba Orchestrator REST API using an API token, queries all
    appliances for interface state and subnet information, and writes sites.csv.proposed
    to the repo root. This is the Windows equivalent of aruba/get_site_details.sh.

    What it collects per appliance:
      - WAN interfaces: IP, public IP (used as customer_gw_ip if present)
      - LAN interfaces: IP/mask from interfaceState
      - Advertised subnets: routes with advert=true or local=true on lan* interfaces
      - BGP/OSPF-learned routes (shown in summary, not written to CSV)

    api_target logic for ec_hostname:
      - EC-V virtual appliances: mgmt0 interface IP
      - Hardware appliances (EC-S, EC-10104): Orchestrator management IP (mgmt0 unconfigured)

.PARAMETER Orchestrator
    Orchestrator hostname or IP address (required).

.PARAMETER Token
    Orchestrator API token. If omitted, reads from $env:ARUBA_API_TOKEN.

.PARAMETER Sites
    Comma-separated list of appliance hostnames to restrict output. Default: all appliances.

.PARAMETER VerifySSL
    Enforce TLS certificate verification. Default: skip verification (required for
    IP-based access with self-signed certs).

.EXAMPLE
    .\Get-SiteDetails.ps1 -Orchestrator 10.0.0.100
    .\Get-SiteDetails.ps1 -Orchestrator 10.0.0.100 -Token "your-api-token"
    .\Get-SiteDetails.ps1 -Orchestrator 10.0.0.100 -Sites "site-a,site-b"
    .\Get-SiteDetails.ps1 -Orchestrator orchestrator.corp.example.com -VerifySSL

.NOTES
    Requires: PowerShell 5.1+
    Output: sites.csv.proposed written to repo root (parent of this script's folder)
    Review output before copying to sites.csv — verify site names, WAN IPs, ec_hostname.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $Orchestrator,

    [string] $Token = $env:ARUBA_API_TOKEN,

    [string] $Sites = "",

    [switch] $VerifySSL
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$TFDir     = Split-Path -Parent $ScriptDir
$OutputFile = Join-Path $TFDir "sites.csv.proposed"

# ---------------------------------------------------------------------------
# Validate inputs
# ---------------------------------------------------------------------------
if (-not $Token) {
    Write-Host "ERROR: API token required. Pass -Token or set `$env:ARUBA_API_TOKEN." -ForegroundColor Red
    exit 1
}

# ---------------------------------------------------------------------------
# TLS handling — skip certificate verification by default (self-signed certs)
# ---------------------------------------------------------------------------
if (-not $VerifySSL) {
    if ($PSVersionTable.PSVersion.Major -ge 6) {
        # PS 7+: pass -SkipCertificateCheck per call (see Invoke-OrchAPI)
    } else {
        # PS 5.1: global callback
        Add-Type @"
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class TrustAllOrchCerts : ICertificatePolicy {
    public bool CheckValidationResult(ServicePoint sp, X509Certificate cert,
        WebRequest req, int problem) { return true; }
}
"@
        [System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllOrchCerts
    }
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Write-Info { param([string]$Msg) Write-Host "INFO  $Msg" }
function Write-Warn { param([string]$Msg) Write-Host "WARN  $Msg" -ForegroundColor Yellow }

function Invoke-OrchAPI {
    param([string]$Endpoint)
    $params = @{
        Method      = "GET"
        Uri         = "https://$Orchestrator/gms/rest/$Endpoint"
        Headers     = @{
            "X-Auth-Token" = $Token
            "Accept"       = "application/json"
        }
        ErrorAction = "Stop"
    }
    if (-not $VerifySSL -and $PSVersionTable.PSVersion.Major -ge 6) {
        $params.SkipCertificateCheck = $true
    }
    return Invoke-RestMethod @params
}

# Returns $true if the IP is a routable public address (not RFC1918, not link-local, not empty)
function Test-IsPublicIP {
    param([string]$IP)
    if (-not $IP -or $IP -eq "0.0.0.0") { return $false }
    if ($IP -match '^10\.')                                    { return $false }
    if ($IP -match '^172\.(1[6-9]|2[0-9]|3[01])\.')           { return $false }
    if ($IP -match '^192\.168\.')                              { return $false }
    if ($IP -match '^169\.254\.')                              { return $false }
    return $true
}

# Normalize appliance hostname to a safe site_name:
# lowercase, non-alphanumeric runs → hyphen, trim leading/trailing hyphens
function Get-NormalizedName {
    param([string]$Hostname)
    return ($Hostname.ToLower() -replace '[^a-z0-9]+', '-').Trim('-')
}

# ---------------------------------------------------------------------------
# Process one appliance
# Returns a PSCustomObject with all collected data
# ---------------------------------------------------------------------------
function Get-ApplianceDetails {
    param(
        [string]$NePk,
        [string]$Hostname,
        [string]$MgmtIP
    )

    Write-Info "  Processing $Hostname ($NePk)..."

    # ---- interfaceState -------------------------------------------------------
    $wanInterfaces  = @()
    $lanInterfaces  = @()
    $customerGwIP   = ""
    $mgmt0IP        = ""

    try {
        $ifaceResp = Invoke-OrchAPI "interfaceState?nePk=$NePk&cached=true"
        $ifInfo    = $ifaceResp.ifInfo

        # WAN interfaces: oper=true, ifname starts with "wan", has a real IPv4
        $wanIfs = $ifInfo | Where-Object {
            $_.oper -eq $true -and
            $_.ifname -like "wan*" -and
            $_.ipv4 -and
            $_.ipv4 -ne "0.0.0.0"
        }

        foreach ($iface in $wanIfs) {
            $wanInterfaces += [PSCustomObject]@{
                ifname   = $iface.ifname
                ipv4     = $iface.ipv4
                prefix   = [string]$iface.ipv4mask
                cidr     = "$($iface.ipv4)/$($iface.ipv4mask)"
                publicIp = if ($iface.PSObject.Properties["publicIp"]) { $iface.publicIp } else { "" }
            }
        }

        # Best customer_gw_ip: first explicit publicIp, then first non-RFC1918 interface IP
        $explicitPublic = $wanInterfaces | Where-Object { $_.publicIp -and $_.publicIp -ne "" } |
            Select-Object -First 1
        if ($explicitPublic) {
            $customerGwIP = $explicitPublic.publicIp
        } else {
            $publicFallback = $wanInterfaces | Where-Object { Test-IsPublicIP $_.ipv4 } |
                Select-Object -First 1
            if ($publicFallback) { $customerGwIP = $publicFallback.ipv4 }
        }

        # LAN interfaces: oper=true, ifname starts with "lan", has a real IPv4
        $lanIfs = $ifInfo | Where-Object {
            $_.oper -eq $true -and
            $_.ifname -like "lan*" -and
            $_.ipv4 -and
            $_.ipv4 -ne "0.0.0.0"
        }
        foreach ($iface in $lanIfs) {
            $lanInterfaces += [PSCustomObject]@{
                ifname = $iface.ifname
                ipv4   = $iface.ipv4
                prefix = [string]$iface.ipv4mask
                cidr   = "$($iface.ipv4)/$($iface.ipv4mask)"
            }
        }

        # mgmt0 IP — used for api_target on EC-V virtual appliances
        $mgmt0If = $ifInfo | Where-Object {
            $_.ifname -eq "mgmt0" -and
            $_.ipv4 -and
            $_.ipv4 -ne "0.0.0.0" -and
            $_.ipv4 -ne "169.254.0.1"
        } | Select-Object -First 1
        if (-not $mgmt0If) {
            # fall back to any mgmt* interface
            $mgmt0If = $ifInfo | Where-Object {
                $_.ifname -like "mgmt*" -and
                $_.ipv4 -and
                $_.ipv4 -ne "0.0.0.0" -and
                $_.ipv4 -ne "169.254.0.1"
            } | Select-Object -First 1
        }
        if ($mgmt0If) { $mgmt0IP = $mgmt0If.ipv4 }

    } catch {
        Write-Warn "    Could not get interfaceState for $Hostname`: $_"
    }

    # api_target: mgmt0 IP for virtual appliances, Orchestrator mgmt IP for hardware
    $apiTarget = if ($mgmt0IP) { $mgmt0IP } else { $MgmtIP }

    # ---- subnets (advertised routes and locally connected LAN subnets) -------
    $advertisedSubnets  = @()
    $bgpLearnedRoutes   = @()
    $ospfLearnedRoutes  = @()

    try {
        $subnetResp = Invoke-OrchAPI "subnets?nePk=$NePk"
        $entries    = $subnetResp.subnets.entries

        foreach ($entry in $entries) {
            $s = $entry.state
            $prefix = $s.prefix

            # Skip default route
            if ($prefix -like "0.0.0.0*") { continue }

            # Advertised subnets: advert=true, or local=true on lan* interface
            $isAdvert = $s.advert -eq $true
            $isLocalLan = $s.local -eq $true -and $s.ifName -like "lan*"
            if ($isAdvert -or $isLocalLan) {
                if ($advertisedSubnets -notcontains $prefix) {
                    $advertisedSubnets += $prefix
                }
            }

            if ($s.PSObject.Properties["learned_bgp"] -and $s.learned_bgp -eq $true) {
                $bgpLearnedRoutes += [PSCustomObject]@{
                    prefix  = $prefix
                    nextHop = $s.nextHop
                    aspath  = if ($s.PSObject.Properties["aspath"]) { $s.aspath } else { "" }
                }
            }
            if ($s.PSObject.Properties["learned_ospf"] -and $s.learned_ospf -eq $true) {
                $ospfLearnedRoutes += [PSCustomObject]@{
                    prefix  = $prefix
                    nextHop = $s.nextHop
                    metric  = if ($s.PSObject.Properties["metric"]) { $s.metric } else { "" }
                }
            }
        }
    } catch {
        Write-Warn "    Could not get subnets for $Hostname`: $_"
    }

    return [PSCustomObject]@{
        NePk              = $NePk
        Hostname          = $Hostname
        MgmtIP            = $MgmtIP
        Mgmt0IP           = $mgmt0IP
        ApiTarget         = $apiTarget
        CustomerGwIP      = $customerGwIP
        WanInterfaces     = $wanInterfaces
        LanInterfaces     = $lanInterfaces
        AdvertisedSubnets = $advertisedSubnets
        BgpLearnedRoutes  = $bgpLearnedRoutes
        OspfLearnedRoutes = $ospfLearnedRoutes
    }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

# Fetch appliance list
Write-Info "Fetching appliance list from $Orchestrator..."
try {
    $applianceList = Invoke-OrchAPI "appliance"
} catch {
    Write-Host "ERROR: Could not reach Orchestrator at $Orchestrator`: $_" -ForegroundColor Red
    exit 1
}

$totalCount = @($applianceList).Count
Write-Info "Found $totalCount appliance(s)"

if ($totalCount -eq 0) {
    Write-Host "ERROR: No appliances returned from Orchestrator." -ForegroundColor Red
    exit 1
}

# Parse -Sites filter
$siteFilter = @()
if ($Sites) {
    $siteFilter = $Sites -split "," | ForEach-Object { $_.Trim().ToLower() }
}

# Process appliances
$results = @()
foreach ($appliance in $applianceList) {
    $nePk     = $appliance.id
    $hostname = $appliance.hostName
    $mgmtIP   = $appliance.IP

    # Apply hostname filter if specified
    if ($siteFilter.Count -gt 0) {
        if ($hostname.ToLower() -notin $siteFilter) { continue }
    }

    $details = Get-ApplianceDetails -NePk $nePk -Hostname $hostname -MgmtIP $mgmtIP
    $results += $details
}

if ($results.Count -eq 0) {
    Write-Host "ERROR: No appliances matched the specified filter." -ForegroundColor Red
    exit 1
}

# ---------------------------------------------------------------------------
# Print summary
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "============================================================"
Write-Host " SITE DETAILS SUMMARY"
Write-Host "============================================================"

foreach ($r in $results) {
    $apiLabel = if ($r.Mgmt0IP) { "$($r.ApiTarget)  [mgmt0]" } else { "$($r.ApiTarget)  [orch mgmt -- no mgmt0 IP]" }
    $gwLabel  = if ($r.CustomerGwIP) { $r.CustomerGwIP } else { "(blank -- NAT/dynamic)" }

    Write-Host "Site: $($r.Hostname) ($($r.NePk))  api_target=$apiLabel"
    Write-Host "  customer_gw_ip:      $gwLabel"

    Write-Host "  WAN interfaces:"
    if ($r.WanInterfaces.Count -gt 0) {
        foreach ($w in $r.WanInterfaces) {
            $pubLabel = if ($w.publicIp) { "  [publicIp: $($w.publicIp)]" } else { "" }
            Write-Host "    $($w.ifname): $($w.cidr)$pubLabel"
        }
    } else {
        Write-Host "    (none active)"
    }

    Write-Host "  LAN interfaces:"
    if ($r.LanInterfaces.Count -gt 0) {
        foreach ($l in $r.LanInterfaces) {
            Write-Host "    $($l.ifname): $($l.cidr)"
        }
    } else {
        Write-Host "    (none active)"
    }

    Write-Host "  Advertised/local LAN subnets:"
    if ($r.AdvertisedSubnets.Count -gt 0) {
        foreach ($s in $r.AdvertisedSubnets) { Write-Host "    $s" }
    } else {
        Write-Host "    (none)"
    }

    Write-Host "  BGP-learned routes:"
    if ($r.BgpLearnedRoutes.Count -gt 0) {
        foreach ($b in $r.BgpLearnedRoutes) {
            Write-Host "    $($b.prefix)  via $($b.nextHop)  aspath=$($b.aspath)"
        }
    } else {
        Write-Host "    (none)"
    }

    Write-Host "  OSPF-learned routes:"
    if ($r.OspfLearnedRoutes.Count -gt 0) {
        foreach ($o in $r.OspfLearnedRoutes) {
            Write-Host "    $($o.prefix)  via $($o.nextHop)  metric=$($o.metric)"
        }
    } else {
        Write-Host "    (none)"
    }

    Write-Host ""
}

Write-Host "============================================================"
Write-Host ""

# ---------------------------------------------------------------------------
# Write sites.csv.proposed
# Sorted alphabetically by normalized site_name — site_index is stable this way.
# ---------------------------------------------------------------------------

# Sort by normalized hostname
$sorted = $results | Sort-Object { Get-NormalizedName $_.Hostname }

Write-Info "Writing $OutputFile ..."

$csvLines = @("site_name,site_index,customer_gw_ip,ec_hostname")
$idx = 0
foreach ($r in $sorted) {
    $siteName = Get-NormalizedName $r.Hostname
    $csvLines += "$siteName,$idx,$($r.CustomerGwIP),$($r.ApiTarget)"
    $idx++
}

$csvLines | Set-Content -Path $OutputFile -Encoding UTF8

Write-Host ""
Write-Info "Written to: $OutputFile"
Write-Host ""
Write-Info "Review before use:"
Write-Info "  1. Verify site_name values are unique and meaningful"
Write-Info "  2. Verify customer_gw_ip -- blank = NAT/dynamic (intentional or needs filling)"
Write-Info "  3. Verify ec_hostname -- replace with DNS name if preferred over IP"
Write-Info "  4. site_index is auto-assigned alphabetically -- do not change once applied"
Write-Info "  5. Once satisfied, copy to sites.csv:"
Write-Info "       Copy-Item '$OutputFile' '$(Join-Path $TFDir "sites.csv")'"
Write-Info "  6. Then run: terraform plan  and  terraform apply -parallelism=1"
