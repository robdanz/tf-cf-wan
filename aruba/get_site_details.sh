#!/usr/bin/env bash
# get_site_details.sh — Query Aruba Orchestrator (and optionally EdgeConnect appliances
# directly) to gather extended per-site information useful for Magic WAN planning.
#
# What it collects per appliance:
#   From Orchestrator:
#     - WAN interfaces: IP, public IP, mask (uses ifname prefix — "wan-if" flag is unreliable)
#     - LAN interfaces: IP/mask from interfaceState
#     - Advertised subnets: routes with advert=true from /subnets endpoint
#     - BGP-learned / OSPF-learned routes
#   From ECOS appliance API (if --ec-user / --ec-pass provided):
#     - BGP neighbor config and session state
#
# Usage:
#   ./get_site_details.sh --orchestrator HOST [OPTIONS]
#
# Options:
#   --orchestrator HOST  Orchestrator hostname or IP (required)
#   --token TOKEN        API token (default: $ARUBA_API_TOKEN)
#   --ec-user USER       EdgeConnect admin username for direct ECOS BGP queries
#   --ec-pass PASS       EdgeConnect admin password for direct ECOS BGP queries
#   --sites SITE,...     Comma-separated appliance hostnames to restrict output (default: all)
#   --verify-ssl         Enforce TLS certificate verification (default: skip)
#   --help

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="$(dirname "$SCRIPT_DIR")"

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
  sed -n '/^# Usage/,/^[^#]/p' "$0" | grep '^#' | sed 's/^# \?//'
  exit 0
}

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
ORCH_HOST=""
API_TOKEN="${ARUBA_API_TOKEN:-}"
EC_USER=""
EC_PASS=""
FILTER_SITES=""
CURL_VERIFY=false

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case $1 in
    --orchestrator) ORCH_HOST="$2";  shift 2 ;;
    --token)        API_TOKEN="$2";  shift 2 ;;
    --ec-user)      EC_USER="$2";    shift 2 ;;
    --ec-pass)      EC_PASS="$2";    shift 2 ;;
    --sites)        FILTER_SITES="$2"; shift 2 ;;
    --verify-ssl)   CURL_VERIFY=true; shift ;;
    --help)         usage ;;
    *) echo "Unknown option: $1" >&2; usage ;;
  esac
done

[[ -z "$ORCH_HOST" ]]  && { echo "ERROR: --orchestrator is required" >&2; exit 1; }
[[ -z "$API_TOKEN" ]]  && { echo "ERROR: API token required via --token or \$ARUBA_API_TOKEN" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
info()  { echo "INFO  $*" >&2; }
warn()  { echo "WARN  $*" >&2; }

ORCH_CURL=(-s -f -H "X-Auth-Token: $API_TOKEN" -H "Accept: application/json")
$CURL_VERIFY || ORCH_CURL+=(-k)

check_deps() {
  for cmd in curl jq; do
    command -v "$cmd" &>/dev/null || { echo "ERROR: $cmd not found in PATH" >&2; exit 1; }
  done
}

orch_get() {
  curl "${ORCH_CURL[@]}" "https://$ORCH_HOST/gms/rest/$1"
}

# ---------------------------------------------------------------------------
# Classify a WAN IP as "public" (usable as customer_gw_ip):
#   - not empty, not 0.0.0.0, not RFC1918, not 169.254.x.x
# ---------------------------------------------------------------------------
is_public_ip() {
  local ip="$1"
  [[ -z "$ip" || "$ip" == "0.0.0.0" ]] && return 1
  [[ "$ip" =~ ^10\. ]]          && return 1
  [[ "$ip" =~ ^172\.(1[6-9]|2[0-9]|3[01])\. ]] && return 1
  [[ "$ip" =~ ^192\.168\. ]]    && return 1
  [[ "$ip" =~ ^169\.254\. ]]    && return 1
  return 0
}

# ---------------------------------------------------------------------------
# ECOS direct: get BGP neighbors for one appliance
#   Returns JSON array or empty array on failure/no-BGP
# ---------------------------------------------------------------------------
ecos_get_bgp() {
  local mgmt_ip="$1"
  local session_file
  session_file=$(mktemp)
  trap "rm -f '$session_file'" RETURN

  local ECOS=(-sk --connect-timeout 5)

  # Login
  local login_resp
  login_resp=$(curl "${ECOS[@]}" -c "$session_file" -X POST \
    -H "Content-Type: application/json" \
    -d "{\"user\":\"$EC_USER\",\"password\":\"$EC_PASS\"}" \
    "https://$mgmt_ip/rest/json/login" 2>/dev/null) || { echo "[]"; return; }

  # Check login success
  echo "$login_resp" | jq -e '.status == 0' &>/dev/null || { echo "[]"; return; }

  # Probe BGP neighbor endpoints
  local bgp_json="[]"
  for ep in "bgp/neighbor" "bgp/neighbors" "bgpNeighbor" "routing/bgp/neighbor"; do
    local resp
    resp=$(curl "${ECOS[@]}" -b "$session_file" \
      "https://$mgmt_ip/rest/json/$ep" 2>/dev/null) || continue
    # If it looks like a non-empty JSON array or object, use it
    if echo "$resp" | jq -e 'if type == "array" then length > 0 elif type == "object" then . != {} else false end' &>/dev/null; then
      bgp_json="$resp"
      break
    fi
  done

  # Logout (best-effort)
  curl "${ECOS[@]}" -b "$session_file" -X DELETE \
    "https://$mgmt_ip/rest/json/login" &>/dev/null || true

  echo "$bgp_json"
}

# ---------------------------------------------------------------------------
# Process one appliance — prints a JSON object for this site
# ---------------------------------------------------------------------------
process_appliance() {
  local ne_pk="$1" hostname="$2" mgmt_ip="$3"

  info "  Processing $hostname ($ne_pk)..."

  # ---- interfaceState -------------------------------------------------------
  local iface_json
  iface_json=$(orch_get "interfaceState?nePk=$ne_pk&cached=true" 2>/dev/null) || iface_json="{}"

  # WAN interfaces: match by ifname prefix "wan", pick publicIp if set else ipv4 if public
  # ipv4mask from this API is an integer prefix length (not dotted-decimal)
  local wan_ip=""
  local wan_details="[]"
  if [[ "$iface_json" != "{}" && -n "$iface_json" ]]; then
    wan_details=$(echo "$iface_json" | jq '[
      .ifInfo[]
      | select(.oper == true and (.ifname | startswith("wan")) and (.ipv4 // "" | length) > 0 and .ipv4 != "0.0.0.0")
      | {
          ifname,
          ipv4,
          prefix: (.ipv4mask | tostring),
          cidr: ("\(.ipv4)/\(.ipv4mask)"),
          publicIp: (.publicIp // "")
        }
    ]' 2>/dev/null || echo "[]")

    # Best customer_gw_ip: first publicIp that is set, else first non-RFC1918 ipv4
    wan_ip=$(echo "$wan_details" | jq -r '
      # prefer explicit publicIp
      ([ .[] | select(.publicIp != "") | .publicIp ] | first) //
      # fall back to non-RFC1918 interface IP
      ([ .[] | select(
        (.ipv4 | test("^10\\.") | not) and
        (.ipv4 | test("^172\\.(1[6-9]|2[0-9]|3[01])\\.") | not) and
        (.ipv4 | test("^192\\.168\\.") | not) and
        (.ipv4 | test("^169\\.254\\.") | not)
      ) | .ipv4 ] | first) //
      ""
    ' 2>/dev/null || echo "")

    local lan_iface_details
    lan_iface_details=$(echo "$iface_json" | jq '[
      .ifInfo[]
      | select(.oper == true and (.ifname | startswith("lan")) and (.ipv4 // "" | length) > 0 and .ipv4 != "0.0.0.0")
      | {
          ifname,
          ipv4,
          prefix: (.ipv4mask | tostring),
          cidr: ("\(.ipv4)/\(.ipv4mask)")
        }
    ]' 2>/dev/null || echo "[]")

    mgmt0_ip=$(echo "$iface_json" | jq -r '
      # Try mgmt0 first (any oper state), then any mgmt* with an IP
      ([ .ifInfo[] | select((.ifname == "mgmt0") and (.ipv4 // "" | length) > 0 and .ipv4 != "0.0.0.0") | .ipv4 ] | first) //
      ([ .ifInfo[] | select((.ifname | startswith("mgmt")) and (.ipv4 // "" | length) > 0 and .ipv4 != "0.0.0.0" and .ipv4 != "169.254.0.1") | .ipv4 ] | first) //
      ""
    ' 2>/dev/null || echo "")
  else
    lan_iface_details="[]"
    mgmt0_ip=""
    warn "    Could not get interfaceState for $hostname"
  fi

  # ---- subnets endpoint (advertised routes) --------------------------------
  local subnet_json
  subnet_json=$(orch_get "subnets?nePk=$ne_pk" 2>/dev/null) || subnet_json='{"subnets":{"entries":[]}}'

  local advertised_subnets bgp_learned_routes ospf_learned_routes
  advertised_subnets=$(echo "$subnet_json" | jq '[
    .subnets.entries[]
    | select(
        (.state.advert == true or
         (.state.local == true and (.state.ifName // "" | startswith("lan")))) and
        (.state.prefix | startswith("0.0.0.0") | not)
      )
    | .state.prefix
  ] | unique' 2>/dev/null || echo "[]")

  bgp_learned_routes=$(echo "$subnet_json" | jq '[
    .subnets.entries[]
    | select(.state.learned_bgp == true)
    | { prefix: .state.prefix, nextHop: .state.nextHop, aspath: .state.aspath }
  ]' 2>/dev/null || echo "[]")

  ospf_learned_routes=$(echo "$subnet_json" | jq '[
    .subnets.entries[]
    | select(.state.learned_ospf == true)
    | { prefix: .state.prefix, nextHop: .state.nextHop, metric: .state.metric }
  ]' 2>/dev/null || echo "[]")

  # ---- BGP via ECOS direct (optional) -------------------------------------
  local mgmt0_ip="${mgmt0_ip:-}"
  local bgp_neighbors="[]"
  if [[ -n "$EC_USER" && -n "$EC_PASS" ]]; then
    info "    Querying ECOS BGP on $mgmt_ip..."
    bgp_neighbors=$(ecos_get_bgp "$mgmt_ip")
  fi

  # ---- Assemble output JSON -----------------------------------------------
  jq -n \
    --arg nepk "$ne_pk" \
    --arg hostname "$hostname" \
    --arg mgmt_ip "$mgmt_ip" \
    --arg mgmt0_ip "$mgmt0_ip" \
    --arg customer_gw_ip "$wan_ip" \
    --argjson wan_interfaces "$wan_details" \
    --argjson lan_interfaces "${lan_iface_details:-[]}" \
    --argjson advertised_subnets "$advertised_subnets" \
    --argjson bgp_learned_routes "$bgp_learned_routes" \
    --argjson ospf_learned_routes "$ospf_learned_routes" \
    --argjson bgp_neighbors "$bgp_neighbors" \
    '{
      ne_pk:             $nepk,
      hostname:          $hostname,
      mgmt_ip:           $mgmt_ip,
      mgmt0_ip:          $mgmt0_ip,
      api_target:        (if $mgmt0_ip != "" then $mgmt0_ip else $mgmt_ip end),
      customer_gw_ip:    $customer_gw_ip,
      wan_interfaces:    $wan_interfaces,
      lan_interfaces:    $lan_interfaces,
      advertised_subnets: $advertised_subnets,
      bgp_learned_routes: $bgp_learned_routes,
      ospf_learned_routes: $ospf_learned_routes,
      bgp_neighbors:     $bgp_neighbors
    }'
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
check_deps

info "Fetching appliance list from $ORCH_HOST..."
APPLIANCE_JSON=$(orch_get "appliance")
APPLIANCE_COUNT=$(echo "$APPLIANCE_JSON" | jq 'length')
info "Found $APPLIANCE_COUNT appliance(s)"

[[ "$APPLIANCE_COUNT" -eq 0 ]] && { echo "ERROR: No appliances returned." >&2; exit 1; }

# Build appliance list, optionally filtered
SITE_RESULTS=()
while IFS=$'\t' read -r ne_pk hostname mgmt_ip; do
  # Apply --sites filter if set
  if [[ -n "$FILTER_SITES" ]]; then
    local_name=$(echo "$hostname" | tr '[:upper:]' '[:lower:]')
    echo ",$FILTER_SITES," | grep -qi ",${local_name}," || continue
  fi
  result=$(process_appliance "$ne_pk" "$hostname" "$mgmt_ip")
  SITE_RESULTS+=("$result")
done < <(echo "$APPLIANCE_JSON" | jq -r '.[] | .id + "\t" + .hostName + "\t" + .IP')

# Combine all site objects into a JSON array and print summary
COMBINED=$(printf '%s\n' "${SITE_RESULTS[@]}" | jq -s '.')

echo ""
echo "============================================================"
echo " SITE DETAILS SUMMARY"
echo "============================================================"
echo "$COMBINED" | jq -r '
  .[] |
  "Site: \(.hostname) (\(.ne_pk))  api_target=\(if .mgmt0_ip != "" then .mgmt0_ip else .mgmt_ip end)\(if .mgmt0_ip != "" then "  [mgmt0]" else "  [orch mgmt — no mgmt0 IP]" end)",
  "  customer_gw_ip:      \(if .customer_gw_ip == "" then "(blank — NAT/dynamic)" else .customer_gw_ip end)",
  "  WAN interfaces:",
  (.wan_interfaces[] | "    \(.ifname): \(.cidr)\(if .publicIp != "" then "  [publicIp: \(.publicIp)]" else "" end)"),
  (if (.wan_interfaces | length) == 0 then "    (none active)" else "" end),
  "  LAN interfaces:",
  (.lan_interfaces[] | "    \(.ifname): \(.cidr)"),
  (if (.lan_interfaces | length) == 0 then "    (none active)" else "" end),
  "  Advertised/local LAN subnets (for lan_subnets):",
  (.advertised_subnets[] | "    \(.)"),
  (if (.advertised_subnets | length) == 0 then "    (none)" else "" end),
  "  BGP-learned routes:",
  (.bgp_learned_routes[] | "    \(.prefix)  via \(.nextHop)  aspath=\(.aspath)"),
  (if (.bgp_learned_routes | length) == 0 then "    (none)" else "" end),
  "  OSPF-learned routes:",
  (.ospf_learned_routes[] | "    \(.prefix)  via \(.nextHop)  metric=\(.metric)"),
  (if (.ospf_learned_routes | length) == 0 then "    (none)" else "" end),
  (if (.bgp_neighbors | length) > 0 then
    "  BGP neighbors (from ECOS):", (.bgp_neighbors | tostring)
  else "" end),
  ""
' 2>/dev/null

echo "============================================================"
echo ""
echo "Full JSON output:"
echo "$COMBINED" | jq .

# ---------------------------------------------------------------------------
# Write sites.csv.proposed
# Sorted alphabetically by site_name so site_index is stable and predictable.
# ec_hostname is set to api_target (mgmt0 if available, else Orchestrator mgmt IP).
# lan_subnets is taken from advertised_subnets — routes the appliance is advertising
# over the SD-WAN fabric (advert=true), plus locally connected subnets on lan*
# interfaces (local=true). The union covers both SD-WAN fabric sites and simpler
# sites where LAN subnets are locally connected but not fabric-advertised.
# ---------------------------------------------------------------------------
CSV_OUTPUT="$TF_DIR/sites.csv.proposed"
info ""
info "Writing $CSV_OUTPUT ..."

{
  echo "site_name,site_index,customer_gw_ip,ec_hostname"
  echo "$COMBINED" | jq -r '
    sort_by(.hostname | ascii_downcase | gsub("[^a-z0-9]+"; "-"))
    | to_entries[]
    | (.value.hostname | ascii_downcase | gsub("[^a-z0-9]+"; "-") | ltrimstr("-") | rtrimstr("-")) as $sname
    | [$sname, (.key | tostring), .value.customer_gw_ip, .value.api_target]
    | join(",")
  '
} > "$CSV_OUTPUT"

info ""
info "Written to: $CSV_OUTPUT"
info ""
info "Review before use:"
info "  1. Verify site_name values are unique and meaningful"
info "  2. Verify customer_gw_ip — blank = NAT/dynamic (intentional or needs filling)"
info "  3. Verify lan_subnets — remove management/transit prefixes you don't want routed"
info "  4. ec_hostname is set to the API target IP — replace with DNS name if preferred"
info "  5. site_index is auto-assigned; do not reuse or change once applied to Cloudflare"
info "  6. Once satisfied: cp $CSV_OUTPUT $TF_DIR/sites.csv"
info "  7. Run: terraform plan && terraform apply -parallelism=1"
