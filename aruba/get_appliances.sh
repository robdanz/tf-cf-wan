#!/usr/bin/env bash
# get_appliances.sh — Query Aruba Orchestrator and generate a proposed sites.csv.
#
# Pulls all approved appliances from Orchestrator, queries each appliance's
# interface state to extract WAN public IP (customer_gw_ip) and LAN subnets,
# then writes a proposed sites.csv for review.
#
# IMPORTANT: This script writes to sites.csv.proposed (not sites.csv directly).
#            Review the output, edit as needed, then rename or merge into sites.csv.
#
# Usage:
#   ./get_appliances.sh --orchestrator HOST [--token TOKEN] [--output FILE] [--verify-ssl]
#
#   The API token can also be set via the ARUBA_API_TOKEN environment variable.
#
# Requirements: curl, jq

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="$(dirname "$SCRIPT_DIR")"

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
  cat <<EOF
Usage: $(basename "$0") --orchestrator HOST [OPTIONS]

Query Aruba Orchestrator for all approved appliances and generate a proposed
sites.csv. Writes to sites.csv.proposed in the terraform directory by default.

Options:
  --orchestrator HOST  Orchestrator hostname or IP (required)
  --token TOKEN        Orchestrator API token (default: \$ARUBA_API_TOKEN env var)
  --output FILE        Output file path (default: ../sites.csv.proposed)
                       Use '--output -' to print to stdout
  --verify-ssl         Enforce TLS certificate verification (default: skip, for IP-based access)
  --help               Show this help

Output columns:
  site_name       Appliance hostname (lowercased, non-alphanumeric -> hyphen)
  site_index      Auto-assigned 0-based index (sorted alphabetically by site_name)
  customer_gw_ip  First active WAN interface publicIp (blank for NAT/dynamic)
  lan_subnets     Comma-separated LAN network CIDRs
  ec_hostname     Appliance management IP (from Orchestrator; replace with DNS name if preferred)

Requirements: curl, jq
EOF
  exit 0
}

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
ORCH_HOST=""
API_TOKEN="${ARUBA_API_TOKEN:-}"
OUTPUT="$TF_DIR/sites.csv.proposed"
CURL_VERIFY=false

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case $1 in
    --orchestrator)  ORCH_HOST="$2";   shift 2 ;;
    --token)         API_TOKEN="$2";   shift 2 ;;
    --output)        OUTPUT="$2";      shift 2 ;;
    --verify-ssl)    CURL_VERIFY=true; shift ;;
    --help)          usage ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
done

[[ -z "$ORCH_HOST" ]]  && { echo "ERROR: --orchestrator is required"; usage; }
[[ -z "$API_TOKEN" ]]  && { echo "ERROR: API token required via --token or \$ARUBA_API_TOKEN"; exit 1; }

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
info()  { echo "INFO  $*" >&2; }
warn()  { echo "WARN  $*" >&2; }
error() { echo "ERROR $*" >&2; }

CURL_OPTS=(-s -f -H "X-Auth-Token: $API_TOKEN" -H "Accept: application/json")
$CURL_VERIFY || CURL_OPTS+=(-k)

check_deps() {
  for cmd in curl jq; do
    command -v "$cmd" &>/dev/null || { error "$cmd not found in PATH"; exit 1; }
  done
}

orch_get() {
  curl "${CURL_OPTS[@]}" "https://$ORCH_HOST/gms/rest/$1"
}

# ---------------------------------------------------------------------------
# Subnet calculation helpers (pure bash, no python needed)
#
# Converts dotted-decimal mask (e.g. 255.255.255.0) to prefix length (24).
# Handles standard contiguous masks only.
# ---------------------------------------------------------------------------
mask_octet_bits() {
  case $1 in
    255) echo 8 ;; 254) echo 7 ;; 252) echo 6 ;; 248) echo 5 ;;
    240) echo 4 ;; 224) echo 3 ;; 192) echo 2 ;; 128) echo 1 ;;
      0) echo 0 ;;
      *) echo 0 ;;  # non-contiguous mask — treat as 0
  esac
}

mask_to_prefix() {
  local mask="$1"
  local IFS=. octets
  read -r -a octets <<< "$mask"
  local prefix=0
  for octet in "${octets[@]}"; do
    prefix=$((prefix + $(mask_octet_bits "$octet")))
  done
  echo "$prefix"
}

# Compute network address: ip AND mask (returns "network/prefix")
ip_mask_to_cidr() {
  local ip="$1" mask="$2"
  local IFS=. ip_octets mask_octets
  read -r -a ip_octets   <<< "$ip"
  read -r -a mask_octets <<< "$mask"
  local prefix
  prefix=$(mask_to_prefix "$mask")
  local o0=$((ip_octets[0] & mask_octets[0]))
  local o1=$((ip_octets[1] & mask_octets[1]))
  local o2=$((ip_octets[2] & mask_octets[2]))
  local o3=$((ip_octets[3] & mask_octets[3]))
  echo "$o0.$o1.$o2.$o3/$prefix"
}

# ---------------------------------------------------------------------------
# Process one appliance — emits a CSV row to stdout
# ---------------------------------------------------------------------------
process_appliance() {
  local ne_pk="$1" hostname="$2" mgmt_ip="$3" index="$4"

  # Sanitize hostname -> site_name: lowercase, replace non-alphanumeric with hyphens
  local site_name
  site_name=$(echo "$hostname" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed 's/^-//;s/-$//')

  # Get interface state
  local iface_json
  iface_json=$(orch_get "interfaceState?nePk=$ne_pk&cached=true" 2>/dev/null) || iface_json="{}"

  if [[ "$iface_json" == "{}" || -z "$iface_json" ]]; then
    warn "Could not get interface state for $hostname ($ne_pk) — using empty values"
    echo "$site_name,$index,,,,$mgmt_ip"
    return
  fi

  # Extract WAN interfaces: prefer publicIp, fall back to ipv4.
  # Use the first active (oper=true) WAN interface, sorted by name for stability.
  local customer_gw_ip
  customer_gw_ip=$(echo "$iface_json" | jq -r '
    [.ifInfo[]
      | select(."wan-if" == true and .oper == true)
      | { name: .ifname, ip: (.publicIp // .ipv4 // "") }
    ]
    | sort_by(.name)
    | first
    | .ip // ""
  ' 2>/dev/null || echo "")

  # Extract LAN interfaces: compute network/prefix for each.
  local lan_cidrs=()
  while IFS=$'\t' read -r lan_ip lan_mask; do
    [[ -z "$lan_ip" || "$lan_ip" == "null" ]] && continue
    [[ -z "$lan_mask" || "$lan_mask" == "null" ]] && continue
    local cidr
    cidr=$(ip_mask_to_cidr "$lan_ip" "$lan_mask")
    lan_cidrs+=("$cidr")
  done < <(echo "$iface_json" | jq -r '
    .ifInfo[]
    | select(."lan-if" == true and .oper == true and .ipv4 != null and .ipv4 != "")
    | [.ipv4, (.ipv4mask // "255.255.255.0")]
    | @tsv
  ' 2>/dev/null || true)

  # Join LAN CIDRs with commas. If multiple, quote the field.
  local lan_subnets=""
  if [[ ${#lan_cidrs[@]} -gt 1 ]]; then
    lan_subnets=$(IFS=,; echo "${lan_cidrs[*]}")
    lan_subnets="\"$lan_subnets\""
  elif [[ ${#lan_cidrs[@]} -eq 1 ]]; then
    lan_subnets="${lan_cidrs[0]}"
  fi

  echo "$site_name,$index,$customer_gw_ip,$lan_subnets,$mgmt_ip"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
check_deps

info "Fetching appliance list from $ORCH_HOST..."
APPLIANCE_JSON=$(orch_get "appliance")

APPLIANCE_COUNT=$(echo "$APPLIANCE_JSON" | jq 'length')
info "Found $APPLIANCE_COUNT appliance(s)"

if [[ "$APPLIANCE_COUNT" -eq 0 ]]; then
  error "No appliances returned. Check Orchestrator connectivity and token."
  exit 1
fi

# Build sorted list: "nePk hostname mgmt_ip" sorted alphabetically by sanitized hostname
SORTED_APPLIANCES=()
while IFS= read -r line; do
  SORTED_APPLIANCES+=("$line")
done < <(echo "$APPLIANCE_JSON" | jq -r '
  .[]
  | (.hostName | ascii_downcase | gsub("[^a-z0-9]+"; "-") | ltrimstr("-") | rtrimstr("-")) as $sname
  | .id + "\t" + .hostName + "\t" + .IP + "\t" + $sname
' | sort -t$'\t' -k4)

# ---------------------------------------------------------------------------
# Generate CSV rows
# ---------------------------------------------------------------------------
info "Querying interface state for each appliance..."

CSV_ROWS=()
CSV_ROWS+=("site_name,site_index,customer_gw_ip,lan_subnets,ec_hostname")

local_index=0
for entry in "${SORTED_APPLIANCES[@]}"; do
  IFS=$'\t' read -r ne_pk hostname mgmt_ip _sname <<< "$entry"
  info "  Processing $hostname ($ne_pk)..."
  row=$(process_appliance "$ne_pk" "$hostname" "$mgmt_ip" "$local_index")
  CSV_ROWS+=("$row")
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
  info "Next steps:"
  info "  1. Review $OUTPUT"
  info "  2. Edit site_name values if needed (must be unique, no spaces)"
  info "  3. Verify customer_gw_ip — blank means NAT/dynamic (intentional or needs filling)"
  info "  4. Verify lan_subnets — remove any management/transit subnets you don't want routed"
  info "  5. Replace ec_hostname IPs with DNS names if preferred"
  info "  6. Once satisfied: cp $OUTPUT $TF_DIR/sites.csv"
  info "  7. Run: terraform plan"
fi
