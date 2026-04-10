#!/usr/bin/env bash
# remove_tunnels.sh — Remove Cloudflare Magic WAN IPsec tunnels from Aruba EdgeConnect appliances.
#
# Backout script for configure_tunnels.sh. Reads the same terraform output to
# identify which tunnels to remove. No separate state required — tunnel names
# are deterministic ({site_name}-pri and {site_name}-sec).
#
# Usage:
#   ./remove_tunnels.sh [--username admin] [--password PASS] [--sites site1,site2] [--dry-run] [--verify-ssl]
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

Remove Cloudflare Magic WAN IPsec tunnels from Aruba EdgeConnect appliances.
Backout script for configure_tunnels.sh.

Options:
  --username USER      EdgeConnect username (default: admin)
  --password PASS      EdgeConnect password (prompted if omitted)
  --sites SITES        Comma-separated site names to process (default: all)
  --dry-run            Print planned removals without making API calls
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

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case $1 in
    --username)      USERNAME="$2";  shift 2 ;;
    --password)      PASSWORD="$2";  shift 2 ;;
    --sites)         SITES="$2";     shift 2 ;;
    --dry-run)       DRY_RUN=true;   shift   ;;
    --verify-ssl)    CURL_VERIFY=true;  shift ;;
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
# Remove tunnels for one appliance
# ---------------------------------------------------------------------------
remove_site() {
  local ec_host="$1" site_name="$2"
  local tunnels expected_names

  tunnels=$(echo "$TUNNEL_DETAILS" | jq --arg s "$site_name" '[.[] | select(.site_name == $s)]')
  expected_names=$(echo "$tunnels" | jq -r '.[].tunnel_name')

  echo ""
  info "Site: $site_name  appliance: $ec_host"

  if $DRY_RUN; then
    while IFS= read -r tname; do
      info "  [DRY RUN] Would remove tunnel: $tname"
      info "  [DRY RUN] Would remove VTI for: $tname"
    done <<< "$expected_names"
    return 0
  fi

  local _COOKIE_JAR="" _CSRF=""

  echo -n "  Logging in to $ec_host... "
  ec_login "$ec_host" || return 1
  echo "OK"

  # Get all existing tunnels: map alias -> tunnel id
  local all_tunnels
  all_tunnels=$(curl $(curl_opts) -b "$_COOKIE_JAR" -H "X-XSRF-TOKEN: $_CSRF" \
    "https://$ec_host/rest/json/thirdPartyTunnels/config" \
    2>/dev/null || echo "{}")

  # Find the tunnel IDs for our expected tunnel names
  local ids_to_delete=()
  while IFS= read -r tname; do
    local tid
    tid=$(echo "$all_tunnels" | jq -r --arg a "$tname" \
      'to_entries[] | select(.value.alias == $a) | .key' 2>/dev/null || echo "")
    if [[ -z "$tid" ]]; then
      warn "  Tunnel '$tname' not found on appliance — skipping"
    else
      info "  Found '$tname' as $tid — queued for deletion"
      ids_to_delete+=("$tid")
    fi
  done <<< "$expected_names"

  if [[ ${#ids_to_delete[@]} -eq 0 ]]; then
    info "  No tunnels to remove on $ec_host"
    ec_logout "$ec_host"
    return 0
  fi

  # Build the delete list JSON and call deleteMultiple
  local delete_payload http_code
  delete_payload=$(printf '%s\n' "${ids_to_delete[@]}" | jq -Rs 'split("\n") | map(select(. != ""))')

  echo -n "  Removing ${#ids_to_delete[@]} tunnel(s)... "
  http_code=$(curl $(curl_opts) -b "$_COOKIE_JAR" -H "X-XSRF-TOKEN: $_CSRF" \
    -X POST "https://$ec_host/rest/json/thirdPartyTunnels/deleteMultiple" \
    -H "Content-Type: application/json" \
    -d "$delete_payload" \
    -o /dev/null -w "%{http_code}" 2>/dev/null) || true

  if [[ "$http_code" == "200" || "$http_code" == "204" ]]; then
    echo "OK"
  else
    echo "FAILED (HTTP $http_code)"
    ec_logout "$ec_host"
    return 1
  fi

  # Remove VTIs associated with our tunnels
  local all_vtis vti_errors=0
  all_vtis=$(curl $(curl_opts) -b "$_COOKIE_JAR" -H "X-XSRF-TOKEN: $_CSRF" \
    "https://$ec_host/rest/json/virtualif/vti" 2>/dev/null || echo "{}")

  while IFS= read -r tname; do
    local vti_key
    vti_key=$(echo "$all_vtis" | jq -r --arg t "$tname" \
      'to_entries[] | select(.value.tunnel == $t) | .key' 2>/dev/null || echo "")
    if [[ -z "$vti_key" ]]; then
      info "  No VTI found for '$tname' — skipping"
    else
      echo -n "  Removing VTI $vti_key (tunnel: $tname)... "
      local vhttp
      vhttp=$(curl $(curl_opts) -b "$_COOKIE_JAR" -H "X-XSRF-TOKEN: $_CSRF" \
        -X DELETE "https://$ec_host/rest/json/virtualif/vti/$vti_key" \
        -o /dev/null -w "%{http_code}" 2>/dev/null) || true
      if [[ "$vhttp" == "200" || "$vhttp" == "204" ]]; then
        echo "OK"
      else
        echo "FAILED (HTTP $vhttp)"
        ((vti_errors += 1)) || true
      fi
    fi
  done <<< "$expected_names"

  ec_logout "$ec_host"
  return "$vti_errors"
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

# Build unique appliance list
APPLIANCE_LIST=()
while IFS= read -r line; do
  APPLIANCE_LIST+=("$line")
done < <(echo "$TUNNEL_DETAILS" | \
  jq -r '[.[]] | unique_by(.ec_hostname) | .[] | .ec_hostname + " " + .site_name' | sort)

if [[ ${#APPLIANCE_LIST[@]} -eq 0 ]]; then
  error "No appliances found. Check ec_hostname values in sites.csv."
  exit 1
fi

info "Sites to remove tunnels from: $(echo "$TUNNEL_DETAILS" | jq -r '[.[].site_name] | unique | sort | join(", ")')"
$DRY_RUN && info "--- DRY RUN (no changes will be made) ---"

# Prompt for password (live run only)
if ! $DRY_RUN && [[ -z "$PASSWORD" ]]; then
  read -rsp "EdgeConnect password for $USERNAME: " PASSWORD
  echo
fi

OVERALL_ERRORS=0
for entry in "${APPLIANCE_LIST[@]}"; do
  ec_host="${entry%% *}"
  site_name="${entry#* }"
  remove_site "$ec_host" "$site_name" || ((OVERALL_ERRORS += 1)) || true
done

echo ""
if [[ "$OVERALL_ERRORS" -eq 0 ]]; then
  info "All tunnels removed successfully."
else
  error "Completed with $OVERALL_ERRORS error(s)."
  exit 1
fi
