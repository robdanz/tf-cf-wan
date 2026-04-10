#!/usr/bin/env bash
# demo_orchestrator.sh — Simulates an Aruba Orchestrator appliance query.
#
# Mimics what get_appliances.sh does against a live Orchestrator, using
# hardcoded demo data. All sites are NAT'd (no public WAN IP). Use this
# to generate a realistic sites.csv.proposed for demo/testing purposes.
#
# Usage:
#   bash aruba/demo_orchestrator.sh [--output FILE]
#   bash aruba/demo_orchestrator.sh --output -    # print to stdout

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="$(dirname "$SCRIPT_DIR")"
OUTPUT="$TF_DIR/sites.csv.proposed"

while [[ $# -gt 0 ]]; do
  case $1 in
    --output) OUTPUT="$2"; shift 2 ;;
    *) echo "Usage: $(basename "$0") [--output FILE]"; exit 1 ;;
  esac
done

info()  { echo "INFO  $*" >&2; }
warn()  { echo "WARN  $*" >&2; }

# ---------------------------------------------------------------------------
# Simulated Orchestrator response: GET /gms/appliance
# In a real run, get_appliances.sh would receive this JSON from the API.
# ---------------------------------------------------------------------------
info "Simulating: GET https://orchestrator/gms/appliance"

MOCK_APPLIANCES='[
  {"id":"1.NE",  "hostName":"chicago-hq",          "IP":"192.168.100.10","model":"EC-XL","softwareVersion":"9.3.4.0","networkRole":"1"},
  {"id":"2.NE",  "hostName":"dallas-branch",        "IP":"192.168.100.11","model":"EC-S", "softwareVersion":"9.3.4.0","networkRole":"0"},
  {"id":"3.NE",  "hostName":"houston-branch",       "IP":"192.168.100.12","model":"EC-S", "softwareVersion":"9.3.4.0","networkRole":"0"},
  {"id":"4.NE",  "hostName":"austin-branch",        "IP":"192.168.100.13","model":"EC-XS","softwareVersion":"9.3.4.0","networkRole":"0"},
  {"id":"5.NE",  "hostName":"denver-branch",        "IP":"192.168.100.14","model":"EC-XS","softwareVersion":"9.3.4.0","networkRole":"0"},
  {"id":"6.NE",  "hostName":"new-york-branch",      "IP":"192.168.100.15","model":"EC-S", "softwareVersion":"9.3.4.0","networkRole":"0"},
  {"id":"7.NE",  "hostName":"los-angeles-branch",   "IP":"192.168.100.16","model":"EC-S", "softwareVersion":"9.3.4.0","networkRole":"0"},
  {"id":"8.NE",  "hostName":"seattle-branch",       "IP":"192.168.100.17","model":"EC-XS","softwareVersion":"9.3.4.0","networkRole":"0"},
  {"id":"9.NE",  "hostName":"boston-branch",        "IP":"192.168.100.18","model":"EC-XS","softwareVersion":"9.3.4.0","networkRole":"0"},
  {"id":"10.NE", "hostName":"miami-branch",         "IP":"192.168.100.19","model":"EC-XS","softwareVersion":"9.3.4.0","networkRole":"0"}
]'

APPLIANCE_COUNT=$(echo "$MOCK_APPLIANCES" | jq 'length')
info "Found $APPLIANCE_COUNT appliance(s)"

# ---------------------------------------------------------------------------
# Simulated interface state per appliance: GET /gms/interfaceState/{nePk}
#
# All sites are behind NAT — no publicIp on WAN interfaces.
# WAN interface has only a private/RFC1918 ip (not useful for customer_gw_ip).
# LAN subnets reflect typical branch office addressing.
# ---------------------------------------------------------------------------

# Returns simulated interface-state JSON for a given nePk (e.g. "5.NE").
# IPs are computed from the numeric site index so this works for any nePk
# without per-site hardcoding.
#
# WAN:  10.0.{N}.2 / 255.255.255.252  (private only — simulates NAT'd site)
# LAN:  10.{N}.0.1 / 255.255.255.0    (standard /24 branch subnet)
# HQ (N=1) additionally gets a second LAN: 10.1.4.1 / 255.255.254.0
mock_iface_state() {
  local ne_pk="$1"
  local n="${ne_pk%.NE}"   # strip ".NE" suffix to get numeric index
  local wan_ip="10.0.${n}.2"
  local lan_ip="10.${n}.0.1"

  if [[ "$n" == "1" ]]; then
    # HQ: two LAN segments
    printf '{"ifInfo":[\n'
    printf '  {"ifname":"wan0","wan-if":true,"lan-if":false,"oper":true,"ipv4":"%s","ipv4mask":"255.255.255.252","publicIp":""},\n' "$wan_ip"
    printf '  {"ifname":"lan0","wan-if":false,"lan-if":true,"oper":true,"ipv4":"%s","ipv4mask":"255.255.252.0"},\n' "$lan_ip"
    printf '  {"ifname":"lan1","wan-if":false,"lan-if":true,"oper":true,"ipv4":"10.1.4.1","ipv4mask":"255.255.254.0"}\n'
    printf ']}\n'
  else
    # Branch: single LAN segment
    printf '{"ifInfo":[\n'
    printf '  {"ifname":"wan0","wan-if":true,"lan-if":false,"oper":true,"ipv4":"%s","ipv4mask":"255.255.255.252","publicIp":""},\n' "$wan_ip"
    printf '  {"ifname":"lan0","wan-if":false,"lan-if":true,"oper":true,"ipv4":"%s","ipv4mask":"255.255.255.0"}\n' "$lan_ip"
    printf ']}\n'
  fi
}

# ---------------------------------------------------------------------------
# Subnet helpers (same as get_appliances.sh)
# ---------------------------------------------------------------------------
mask_octet_bits() {
  case $1 in
    255) echo 8 ;; 254) echo 7 ;; 252) echo 6 ;; 248) echo 5 ;;
    240) echo 4 ;; 224) echo 3 ;; 192) echo 2 ;; 128) echo 1 ;;
      0) echo 0 ;;  *) echo 0 ;;
  esac
}

mask_to_prefix() {
  local mask="$1" IFS=. octets
  read -r -a octets <<< "$mask"
  local prefix=0
  for octet in "${octets[@]}"; do
    prefix=$((prefix + $(mask_octet_bits "$octet")))
  done
  echo "$prefix"
}

ip_mask_to_cidr() {
  local ip="$1" mask="$2" IFS=. ip_octets mask_octets
  read -r -a ip_octets   <<< "$ip"
  read -r -a mask_octets <<< "$mask"
  local o0=$((ip_octets[0] & mask_octets[0]))
  local o1=$((ip_octets[1] & mask_octets[1]))
  local o2=$((ip_octets[2] & mask_octets[2]))
  local o3=$((ip_octets[3] & mask_octets[3]))
  local prefix
  prefix=$(mask_to_prefix "$mask")
  echo "$o0.$o1.$o2.$o3/$prefix"
}

# ---------------------------------------------------------------------------
# Process each appliance
# ---------------------------------------------------------------------------
info "Querying interface state for each appliance..."

CSV_ROWS=("site_name,site_index,customer_gw_ip,lan_subnets,ec_hostname")

# Sort appliances alphabetically by hostname for stable index assignment
SORTED_APPLIANCES=()
while IFS= read -r line; do
  SORTED_APPLIANCES+=("$line")
done < <(echo "$MOCK_APPLIANCES" | jq -r '
  .[]
  | (.hostName | ascii_downcase | gsub("[^a-z0-9]+"; "-") | ltrimstr("-") | rtrimstr("-")) as $sname
  | .id + "\t" + .hostName + "\t" + .IP + "\t" + $sname
' | sort -t$'\t' -k4)

local_index=0
for entry in "${SORTED_APPLIANCES[@]}"; do
  IFS=$'\t' read -r ne_pk hostname mgmt_ip _sname <<< "$entry"

  info "  Simulating: GET https://orchestrator/gms/interfaceState/$ne_pk?cached=true"
  info "    -> $hostname ($ne_pk) mgmt=$mgmt_ip"

  site_name=$(echo "$hostname" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed 's/^-//;s/-$//')
  iface_json=$(mock_iface_state "$ne_pk")

  # WAN: publicIp is blank for all NAT'd sites -> customer_gw_ip will be empty
  customer_gw_ip=$(echo "$iface_json" | jq -r '
    [.ifInfo[] | select(."wan-if" == true and .oper == true)
      | { name: .ifname, ip: (.publicIp // "") }]
    | sort_by(.name) | first | .ip // ""
  ')
  [[ -z "$customer_gw_ip" ]] && info "    -> WAN: no publicIp detected (NAT'd site — customer_gw_ip will be blank)"

  # LAN subnets
  lan_cidrs=()
  while IFS=$'\t' read -r lan_ip lan_mask; do
    [[ -z "$lan_ip" || "$lan_ip" == "null" ]] && continue
    lan_cidrs+=("$(ip_mask_to_cidr "$lan_ip" "$lan_mask")")
  done < <(echo "$iface_json" | jq -r '
    .ifInfo[] | select(."lan-if" == true and .oper == true and .ipv4 != null and .ipv4 != "")
    | [.ipv4, (.ipv4mask // "255.255.255.0")] | @tsv
  ')

  lan_subnets=""
  if [[ ${#lan_cidrs[@]} -gt 1 ]]; then
    lan_subnets=$(IFS=,; echo "${lan_cidrs[*]}")
    lan_subnets="\"$lan_subnets\""
  elif [[ ${#lan_cidrs[@]} -eq 1 ]]; then
    lan_subnets="${lan_cidrs[0]}"
  fi

  info "    -> LAN subnets: ${lan_subnets:-"(none)"}"

  CSV_ROWS+=("$site_name,$local_index,$customer_gw_ip,$lan_subnets,$mgmt_ip")
  ((local_index += 1)) || true
done

# ---------------------------------------------------------------------------
# Write output
# ---------------------------------------------------------------------------
OUTPUT_CONTENT=$(printf '%s\n' "${CSV_ROWS[@]}")

if [[ "$OUTPUT" == "-" ]]; then
  echo "$OUTPUT_CONTENT"
else
  echo "$OUTPUT_CONTENT" > "$OUTPUT"
  info ""
  info "Written to: $OUTPUT"
  info ""
  info "Note: All sites are NAT'd — customer_gw_ip is intentionally blank."
  info "      EdgeConnect will use its own WAN IP for IKE negotiation."
  info ""
  info "Next steps:"
  info "  1. Review $OUTPUT"
  info "  2. cp $OUTPUT $TF_DIR/sites.csv"
  info "  3. terraform plan && terraform apply"
  info "  4. bash aruba/generate_curl_commands.sh"
fi
