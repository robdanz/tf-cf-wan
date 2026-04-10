#!/usr/bin/env bash
# configure_tunnels.sh — Create Cloudflare Magic WAN IPsec tunnels on Aruba EdgeConnect appliances.
#
# Reads tunnel data directly from terraform output (no separate config files needed).
# Run `terraform apply` in the parent directory before running this script.
#
# Usage:
#   ./configure_tunnels.sh [--username admin] [--password PASS] [--sites site1,site2] [--dry-run] [--verify-ssl]
#   ./configure_tunnels.sh [--orchestrator ORCH] [--orch-token TOKEN] ...
#
# Requirements: curl, jq, terraform

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="$(dirname "$SCRIPT_DIR")"

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Configure Cloudflare Magic WAN IPsec tunnels on Aruba EdgeConnect appliances.
Reads tunnel data from 'terraform output' in the parent directory.

Options:
  --username USER      EdgeConnect username (default: admin)
  --password PASS      EdgeConnect password (prompted if omitted)
  --sites SITES        Comma-separated site names to process (default: all)
  --orchestrator ORCH  Orchestrator hostname/IP — required for NAT'd sites (blank customer_gw_ip)
  --orch-token TOKEN   Orchestrator API token (default: \$ARUBA_API_TOKEN)
  --dry-run            Print planned changes without making API calls
  --verify-ssl         Enforce TLS certificate verification (default: skip, for IP-based access)
  --help               Show this help

Requirements: curl, jq, terraform
EOF
  exit 0
}

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
USERNAME="admin"
PASSWORD=""
SITES=""
DRY_RUN=false
CURL_VERIFY=false
ORCH_HOST=""
ORCH_TOKEN="${ARUBA_API_TOKEN:-}"

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case $1 in
    --username)      USERNAME="$2";    shift 2 ;;
    --password)      PASSWORD="$2";    shift 2 ;;
    --sites)         SITES="$2";       shift 2 ;;
    --orchestrator)  ORCH_HOST="$2";   shift 2 ;;
    --orch-token)    ORCH_TOKEN="$2";  shift 2 ;;
    --dry-run)       DRY_RUN=true;     shift   ;;
    --verify-ssl)    CURL_VERIFY=true; shift   ;;
    --help)          usage ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
done

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
info()  { echo "INFO  $*"; }
warn()  { echo "WARN  $*"; }
error() { echo "ERROR $*" >&2; }

curl_opts() {
  local opts=(-s -f)
  $CURL_VERIFY || opts+=(-k)
  echo "${opts[@]}"
}

check_deps() {
  for cmd in curl jq terraform; do
    command -v "$cmd" &>/dev/null || { error "$cmd not found in PATH"; exit 1; }
  done
}

# ---------------------------------------------------------------------------
# EdgeConnect auth
# ---------------------------------------------------------------------------
ec_login() {
  local host="$1"
  # Sets _COOKIE_JAR and _CSRF in the caller's scope on success
  _COOKIE_JAR=$(mktemp)
  local http_code
  http_code=$(curl $(curl_opts) -c "$_COOKIE_JAR" -o /dev/null -w "%{http_code}" \
    -X POST "https://$host/rest/json/login" \
    -H "Content-Type: application/json" \
    -d "{\"user\":\"$USERNAME\",\"password\":\"$PASSWORD\"}" 2>/dev/null) || true
  sed -i.bak 's/^#HttpOnly_//' "$_COOKIE_JAR" && rm -f "${_COOKIE_JAR}.bak"
  _CSRF=$(awk '/edgeosCsrfToken/{print $NF}' "$_COOKIE_JAR")
  if [[ "$http_code" != "200" && "$http_code" != "204" ]] || [[ -z "$_CSRF" ]]; then
    error "Login to $host failed (HTTP $http_code)"
    rm -f "$_COOKIE_JAR"
    return 1
  fi
}

ec_logout() {
  local host="$1"
  curl $(curl_opts) -b "$_COOKIE_JAR" -H "X-XSRF-TOKEN: $_CSRF" \
    -X DELETE "https://$host/rest/json/login" -o /dev/null 2>/dev/null || true
  rm -f "$_COOKIE_JAR"
  _COOKIE_JAR=""
  _CSRF=""
}

# ---------------------------------------------------------------------------
# Orchestrator helpers
# ---------------------------------------------------------------------------
orch_curl() {
  local flags=(-s
    -H "X-Auth-Token: $ORCH_TOKEN"
    -H "Content-Type: application/json"
    -H "X-Requested-With: XMLHttpRequest")
  $CURL_VERIFY || flags+=(-k)
  curl "${flags[@]}" "$@"
}

# Look up the Orchestrator nePk for a given appliance management IP.
# Returns empty string on failure.
lookup_nepk() {
  local ec_host="$1"
  orch_curl "https://$ORCH_HOST/gms/rest/appliance" \
    | jq -r --arg ip "$ec_host" '.[] | select(.IP == $ip) | .id' 2>/dev/null || echo ""
}

# Get the first WAN interface IPv4 address for a given nePk.
# Used as the tunnel source IP for NAT'd sites (where customer_gw_ip is blank).
get_wan_ip() {
  local ne_pk="$1"
  [[ -z "$ORCH_HOST" || -z "$ne_pk" ]] && echo "" && return
  orch_curl "https://$ORCH_HOST/gms/rest/interfaceState?nePk=${ne_pk}&cached=true" \
    | jq -r '[.ifInfo[] | select(.ifname | startswith("wan"))
              | select(.ipv4 != null and .ipv4 != "")
              | .ipv4][0] // ""' 2>/dev/null || echo ""
}

# Create a VTI on the appliance (ECOS API) for one tunnel.
# Uses the existing ECOS session (_COOKIE_JAR / _CSRF).
# Skips if a VTI already exists for this tunnel.
create_vti() {
  local ec_host="$1" tunnel_json="$2"

  local tname cpe_ip prefix_len
  tname=$(echo "$tunnel_json" | jq -r '.tunnel_name')
  cpe_ip=$(echo "$tunnel_json" | jq -r '.cpe_inside_ip')
  prefix_len=$(echo "$tunnel_json" | jq -r '.interface_address' | cut -d/ -f2)

  # GET existing VTIs — check idempotency and find next vtiN number
  local existing
  existing=$(curl $(curl_opts) -b "$_COOKIE_JAR" -H "X-XSRF-TOKEN: $_CSRF" \
    "https://$ec_host/rest/json/virtualif/vti" 2>/dev/null || echo "{}")

  local existing_key
  existing_key=$(echo "$existing" | jq -r --arg t "$tname" \
    'to_entries[] | select(.value.tunnel == $t) | .key' 2>/dev/null || echo "")
  if [[ -n "$existing_key" ]]; then
    info "    VTI SKIP: already exists ($existing_key)"
    return 0
  fi

  # Pick next available vtiN key
  local next_num vti_key
  next_num=$(echo "$existing" | jq -r '
    [keys[] | select(test("^vti[0-9]+$")) | ltrimstr("vti") | tonumber]
    | if length == 0 then 110 else (max + 1) end')
  vti_key="vti${next_num}"

  local payload
  payload=$(jq -nc \
    --arg tname "$tname" \
    --arg ip    "$cpe_ip" \
    --argjson mask "$prefix_len" \
    '{
      admin:           true,
      auto_distribute: true,
      behindNAT:       "none",
      gms_marked:      false,
      ipaddr:          $ip,
      ipaddr_alias:    "0.0.0.0",
      label:           "",
      label_alias:     "",
      nmask:           $mask,
      nmask_alias:     0,
      role_id:         0,
      side:            "lan",
      tunnel:          $tname,
      vrf_id:          0,
      zone:            0
    }')

  local http_code
  http_code=$(curl $(curl_opts) -b "$_COOKIE_JAR" -H "X-XSRF-TOKEN: $_CSRF" \
    -X POST "https://$ec_host/rest/json/virtualif/vti/$vti_key" \
    -H "Content-Type: application/json" \
    -d "$payload" \
    -o /dev/null -w "%{http_code}" 2>/dev/null) || true

  if [[ "$http_code" == "200" || "$http_code" == "201" || "$http_code" == "204" ]]; then
    info "    VTI OK ($vti_key)"
  else
    warn "    VTI FAILED (HTTP $http_code)"
    return 1
  fi
}

# ---------------------------------------------------------------------------
# Build tunnel config payload for a single tunnel.
#
# Phase 1 (IKE):  AES-256, SHA-256, DH Group 20, IKEv2
# Phase 2 (ESP):  AES-256, PFS Group 20
# Mode:           ipsec_ip (IPsec passthrough)
# Local identity: FQDN (fqdn_id from terraform output)
#
# $3 = fallback_source: appliance local WAN IP, used when customer_endpoint is
#      empty (NAT'd sites). Required — ipsec_ip rejects "0.0.0.0" and "".
# ---------------------------------------------------------------------------
build_tunnel_payload() {
  local tunnel_json="$1" psk="$2" fallback_source="${3:-}"
  jq -n \
    --argjson t "$tunnel_json" \
    --arg psk "$psk" \
    --arg fs  "$fallback_source" \
    '{
      ($t.tunnel_name): {
        admin:        "up",
        alias:        $t.tunnel_name,
        auto_mtu:     true,
        gms_marked:   false,
        ipsec_enable:     true,
        ipsec_arc_window: "disable",
        presharedkey: $psk,
        mode:         "ipsec_ip",
        nat_mode:     "none",
        peername:     "Cloudflare_IPSec",
        source:       (if ($t.customer_endpoint // "") != "" then $t.customer_endpoint elif $fs != "" then $fs else error("source IP required: set customer_gw_ip in sites.csv or pass --orchestrator for auto-resolution") end),
        destination:  $t.cloudflare_endpoint,
        max_bw_auto:  true,
        local_vrf:    0,
        ipsec: {
          ike_version:   2,
          ike_ealg:      "aes256",
          ike_aalg:      "sha256",
          ike_prf:       "auto",
          dhgroup:       "14",
          pfs:           true,
          pfsgroup:      "14",
          ipsec_suite_b: "none",
          id_type:       "ufqdn",
          ike_id_local:  $t.fqdn_id,
          ike_id_remote: $t.cloudflare_endpoint,
          exchange_mode: "aggressive",
          mode:          "tunnel",
          esn:           false,
          dpd_delay:     0,
          dpd_retry:     3,
          ike_lifetime:  0,
          lifetime:      240,
          lifebytes:     0,
          security: {
            ah:  { algorithm: "sha256" },
            esp: { algorithm: "aes256" }
          }
        }
      }
    }'
}

# ---------------------------------------------------------------------------
# Configure one appliance
# ---------------------------------------------------------------------------
configure_site() {
  local ec_host="$1" site_name="$2"
  local tunnels tunnel_count

  tunnels=$(echo "$TUNNEL_DETAILS" | jq --arg s "$site_name" '[.[] | select(.site_name == $s)]')
  tunnel_count=$(echo "$tunnels" | jq 'length')

  echo ""
  info "Site: $site_name  appliance: $ec_host  tunnels: $tunnel_count"

  if $DRY_RUN; then
    while IFS= read -r t; do
      local tname remote local_ip
      tname=$(echo "$t" | jq -r '.tunnel_name')
      remote=$(echo "$t" | jq -r '.cloudflare_endpoint')
      local_ip=$(echo "$t" | jq -r 'if (.customer_endpoint == "" or .customer_endpoint == null) then "(dynamic)" else .customer_endpoint end')
      info "  [DRY RUN] Would create tunnel: $tname  remote=$remote  local=$local_ip"
      info "  [DRY RUN] Would create VTI: $tname  ip=$(echo "$t" | jq -r '.cpe_inside_ip')/$(echo "$t" | jq -r '.interface_address' | cut -d/ -f2)"
    done < <(echo "$tunnels" | jq -c '.[]')
    return 0
  fi

  local _COOKIE_JAR="" _CSRF=""

  # Resolve WAN IP once per appliance for NAT'd sites (customer_endpoint blank).
  # ipsec_ip mode requires a real source IP — "0.0.0.0" is rejected.
  local site_wan_ip=""
  if [[ -n "$ORCH_HOST" ]] && echo "$tunnels" | jq -e '[.[] | select((.customer_endpoint // "") == "")] | length > 0' > /dev/null 2>&1; then
    local site_ne_pk
    site_ne_pk=$(lookup_nepk "$ec_host")
    if [[ -n "$site_ne_pk" ]]; then
      site_wan_ip=$(get_wan_ip "$site_ne_pk")
      [[ -n "$site_wan_ip" ]] && info "  Resolved WAN IP for source: $site_wan_ip"
    fi
  fi

  echo -n "  Logging in to $ec_host... "
  ec_login "$ec_host" || return 1
  echo "OK"

  # Get existing tunnel aliases to make this idempotent
  local existing_aliases
  existing_aliases=$(curl $(curl_opts) -b "$_COOKIE_JAR" -H "X-XSRF-TOKEN: $_CSRF" \
    "https://$ec_host/rest/json/thirdPartyTunnels/config" \
    2>/dev/null | jq -r '.[].alias' 2>/dev/null || echo "")

  local errors=0
  while IFS= read -r tunnel_json; do
    local tname
    tname=$(echo "$tunnel_json" | jq -r '.tunnel_name')

    if echo "$existing_aliases" | grep -qxF "$tname"; then
      info "  SKIP tunnel: '$tname' already exists on appliance"
      # Still attempt VTI creation — it may have been missed previously
      create_vti "$ec_host" "$tunnel_json" || ((errors += 1)) || true
      continue
    fi

    local payload http_code
    payload=$(build_tunnel_payload "$tunnel_json" "$PSK" "$site_wan_ip")

    echo -n "  Creating tunnel $tname... "
    http_code=$(curl $(curl_opts) -b "$_COOKIE_JAR" -H "X-XSRF-TOKEN: $_CSRF" \
      -X POST "https://$ec_host/rest/json/thirdPartyTunnels/config" \
      -H "Content-Type: application/json" \
      -d "$payload" \
      -o /dev/null -w "%{http_code}" 2>/dev/null) || true

    if [[ "$http_code" == "200" || "$http_code" == "204" ]]; then
      echo "OK"
      create_vti "$ec_host" "$tunnel_json" || ((errors += 1)) || true
    else
      echo "FAILED (HTTP $http_code)"
      ((errors += 1)) || true
    fi
  done < <(echo "$tunnels" | jq -c '.[]')

  ec_logout "$ec_host"
  return "$errors"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
check_deps

cd "$TF_DIR"
info "Reading terraform outputs..."

TUNNEL_DETAILS=$(terraform output -json tunnel_details 2>/dev/null) || {
  error "Could not read terraform outputs. Run 'terraform apply' first."
  exit 1
}
PSK=$(terraform output -raw tunnel_psk 2>/dev/null) || {
  error "Could not read tunnel_psk. Run 'terraform apply' first."
  exit 1
}

# Filter by --sites
if [[ -n "$SITES" ]]; then
  FILTER=$(echo "$SITES" | sed 's/,/|/g')
  TUNNEL_DETAILS=$(echo "$TUNNEL_DETAILS" | \
    jq --arg f "$FILTER" 'with_entries(select(.value.site_name | test("^(" + $f + ")$")))')
  [[ $(echo "$TUNNEL_DETAILS" | jq 'length') -eq 0 ]] && {
    error "No tunnels matched --sites '$SITES'"
    exit 1
  }
fi

# Build unique appliance list: "ec_hostname site_name"
APPLIANCE_LIST=()
while IFS= read -r line; do
  APPLIANCE_LIST+=("$line")
done < <(echo "$TUNNEL_DETAILS" | \
  jq -r '[.[]] | unique_by(.ec_hostname) | .[] | .ec_hostname + " " + .site_name' | sort)

if [[ ${#APPLIANCE_LIST[@]} -eq 0 ]]; then
  error "No appliances found. Check ec_hostname values in sites.csv."
  exit 1
fi

info "Sites to configure: $(echo "$TUNNEL_DETAILS" | jq -r '[.[].site_name] | unique | sort | join(", ")')"
[[ -n "$ORCH_HOST" ]] && info "Orchestrator: $ORCH_HOST (WAN IP resolution for NAT'd sites enabled)"
$DRY_RUN && info "--- DRY RUN (no changes will be made) ---"

# Prompt for password (live run only)
if ! $DRY_RUN && [[ -z "$PASSWORD" ]]; then
  read -rsp "EdgeConnect password for $USERNAME: " PASSWORD
  echo
fi

# Prompt for Orchestrator token if orchestrator is set but token is missing
if [[ -n "$ORCH_HOST" ]] && ! $DRY_RUN && [[ -z "$ORCH_TOKEN" ]]; then
  read -rsp "Orchestrator API token: " ORCH_TOKEN
  echo
fi

OVERALL_ERRORS=0
for entry in "${APPLIANCE_LIST[@]}"; do
  ec_host="${entry%% *}"
  site_name="${entry#* }"
  configure_site "$ec_host" "$site_name" || ((OVERALL_ERRORS += 1)) || true
done

echo ""
if [[ "$OVERALL_ERRORS" -eq 0 ]]; then
  info "All tunnels configured successfully."
else
  error "Completed with $OVERALL_ERRORS error(s)."
  exit 1
fi
