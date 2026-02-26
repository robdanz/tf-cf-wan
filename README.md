# tf-mwan

Terraform project to manage Cloudflare Magic WAN IPsec tunnels at scale. Creates 2 IPsec tunnels per site (one to each Cloudflare Anycast IP) and outputs a CSV for CPE configuration.

## Prerequisites

- Terraform >= 1.5.0
- Cloudflare API token with **Magic WAN: Edit** + **Account Settings: Read** (account-level)
- Cloudflare account with Magic WAN enabled

## Quick Start

```bash
cp terraform.tfvars.example terraform.tfvars
# Fill in terraform.tfvars with your account credentials and Anycast IPs
# Edit sites.csv with your site data
terraform init
terraform plan
terraform apply
```

After apply, the CPE configuration CSV is at `output/cpe-config.csv`.

## Input: sites.csv

| Column | Required | Description |
|---|---|---|
| `site_name` | Yes | Unique site identifier (alphanumeric, hyphens, underscores). Becomes part of the tunnel name. |
| `site_index` | Yes | Integer starting at 0. Determines /31 IP allocation from the supernet. Must be unique. |
| `customer_gw_ip` | Yes | CPE public WAN IP (IPsec endpoint). |
| `lan_subnets` | No | Comma-delimited CIDRs for Cloudflare static routes. Quote the field when providing multiple subnets. |

Example:
```csv
site_name,site_index,customer_gw_ip,lan_subnets
hq,0,203.0.113.1,
branch-chicago,1,198.51.100.10,192.168.1.0/24
branch-denver,2,198.51.100.20,"192.168.1.0/24,192.168.2.0/24"
```

## IP Allocation

Inside tunnel addresses are allocated from `10.120.0.0/22` (512 /31 subnets, max 256 sites):

- Site at `site_index` **i**:
  - Primary tunnel (Anycast 1): `/31` subnet index = `i * 2`
  - Secondary tunnel (Anycast 2): `/31` subnet index = `i * 2 + 1`
- Within each /31: Cloudflare = lower (even) IP, CPE = upper (odd) IP

Example for `site_index=0`:
```
pri: 10.120.0.0/31  (CF: 10.120.0.0, CPE: 10.120.0.1)
sec: 10.120.0.2/31  (CF: 10.120.0.2, CPE: 10.120.0.3)
```

## Output: aruba-config.csv

Generated at `output/cpe-config.csv` after `terraform apply`. Contains all values needed to configure the CPE:

| Column | Description |
|---|---|
| `site_name` | Site identifier |
| `tunnel_label` | `pri` or `sec` |
| `tunnel_name` | Cloudflare tunnel name (`<site>-<pri\|sec>`) |
| `tunnel_id` | Cloudflare tunnel UUID |
| `cloudflare_anycast_ip` | Cloudflare Anycast endpoint IP |
| `customer_gw_ip` | CPE public WAN IP |
| `interface_address_cidr` | /31 tunnel subnet |
| `cf_inside_ip` | Cloudflare tunnel inner IP |
| `cpe_inside_ip` | IP to configure on the CPE tunnel interface |
| `fqdn_id` | Local IKE Identifier (Cloudflare-generated FQDN) |
| `psk` | Pre-shared key |

## Validating fqdn_id

After the first `terraform apply`, verify the `fqdn_id` is populated:

```bash
terraform state show 'cloudflare_magic_wan_ipsec_tunnel.tunnels["test-hq-pri"]'
```

If `fqdn_id` shows `CHECK_DASHBOARD`, look it up manually: **Cloudflare Dashboard > Magic WAN > Connectors > [tunnel] > IKE Identity**.

## Variables

| Variable | Default | Description |
|---|---|---|
| `cloudflare_api_token` | *(required)* | API token — Magic WAN: Edit + Account Settings: Read |
| `cloudflare_account_id` | *(required)* | Cloudflare account ID |
| `cloudflare_conduit_id` | *(required)* | Conduit ID for IKE FQDN identifier (from your account team) |
| `anycast_ip_1` | *(required)* | Primary Anycast IP (from your account team) |
| `anycast_ip_2` | *(required)* | Secondary Anycast IP (from your account team) |
| `tunnel_supernet` | *(required)* | Supernet for /31 inside address allocation |
| `health_check_direction` | `unidirectional` | `unidirectional` or `bidirectional` |
| `health_check_type` | `reply` | `reply` or `request` |
| `health_check_rate` | `mid` | `low`, `mid`, or `high` |
| `replay_protection` | `false` | IPsec anti-replay (disable if your CPE has compatibility issues) |

## Retrieving the PSK

The pre-shared key is generated once and shared across all tunnels. Retrieve it after apply:

```bash
terraform output -raw tunnel_psk
```

The PSK is also included in `output/aruba-config.csv` for convenience.

## Security

- `terraform.tfvars` contains the API token — gitignored, never commit it
- `output/` contains the PSK in plaintext — gitignored
- `terraform.tfstate` contains the PSK — keep it local and secure
- PSK is generated once on first apply and stable across subsequent applies
