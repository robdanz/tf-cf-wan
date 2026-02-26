# tf-mwan

Terraform project to manage Cloudflare WAN (Magic WAN) IPsec tunnels at scale. Creates 2 IPsec tunnels per site (one to each Cloudflare Anycast IP) and outputs a CSV for Aruba EdgeConnect SDWAN configuration.

## Prerequisites

- Terraform >= 1.5.0
- Cloudflare API token with **Magic WAN: Edit** + **Account Settings: Read** (account-level)
- Cloudflare account with Magic WAN enabled

## Quick Start

```bash
terraform init
# Edit sites.csv with your site data
# Set your API token in terraform.tfvars
terraform plan
terraform apply
```

After apply, the Aruba configuration CSV is at `output/aruba-config.csv`.

## Input: sites.csv

| Column | Required | Description |
|---|---|---|
| `site_name` | Yes | Unique site identifier (alphanumeric, hyphens, underscores). Becomes part of the tunnel name. |
| `site_index` | Yes | Integer starting at 0. Determines /31 IP allocation from the supernet. Must be unique. |
| `customer_gw_ip` | Yes | Aruba EdgeConnect public WAN IP (IPsec endpoint). |
| `lan_subnets` | No | Placeholder for future static routes. Semicolon-delimited CIDRs (e.g. `192.168.1.0/24;10.10.0.0/16`). |

Example:
```csv
site_name,site_index,customer_gw_ip,lan_subnets
hq,0,203.0.113.1,
branch-chicago,1,198.51.100.10,
branch-denver,2,198.51.100.20,192.168.1.0/24;192.168.2.0/24
```

## IP Allocation

Inside tunnel addresses are allocated from `10.120.0.0/22` (512 /31 subnets, max 256 sites):

- Site at `site_index` **i**:
  - Primary tunnel (Anycast 1): `/31` subnet index = `i * 2`
  - Secondary tunnel (Anycast 2): `/31` subnet index = `i * 2 + 1`
- Within each /31: Cloudflare = lower (even) IP, Aruba = upper (odd) IP

Example for `site_index=0`:
```
pri: 10.120.0.0/31  (CF: 10.120.0.0, Aruba: 10.120.0.1)
sec: 10.120.0.2/31  (CF: 10.120.0.2, Aruba: 10.120.0.3)
```

## Output: aruba-config.csv

Generated at `output/aruba-config.csv` after `terraform apply`. Contains all values the Aruba team needs:

| Column | Description |
|---|---|
| `site_name` | Site identifier |
| `tunnel_label` | `pri` or `sec` |
| `tunnel_name` | Cloudflare tunnel name (`<site>-<pri\|sec>`) |
| `tunnel_id` | Cloudflare tunnel UUID |
| `cloudflare_anycast_ip` | Cloudflare Anycast endpoint IP |
| `customer_gw_ip` | Aruba WAN IP |
| `interface_address_cidr` | /31 tunnel subnet |
| `cf_inside_ip` | Cloudflare tunnel inner IP |
| `aruba_inside_ip` | IP to configure on Aruba tunnel interface |
| `fqdn_id` | Aruba "Local IKE Identifier" (Cloudflare-generated FQDN) |
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
| `cloudflare_api_token` | *(required)* | API token (sensitive) |
| `cloudflare_account_id` | `909f139a...` | Account ID |
| `anycast_ip_1` | `162.159.66.205` | Primary Anycast IP |
| `anycast_ip_2` | `172.64.242.205` | Secondary Anycast IP |
| `tunnel_supernet` | `10.120.0.0/22` | /31 allocation supernet |
| `health_check_direction` | `unidirectional` | `unidirectional` or `bidirectional` |
| `health_check_type` | `reply` | `reply` or `request` |
| `health_check_rate` | `mid` | `low`, `mid`, or `high` |
| `replay_protection` | `false` | IPsec anti-replay |

## Security

- `terraform.tfvars` contains the API token and is gitignored
- `output/` directory contains the PSK in plaintext and is gitignored
- State file (`terraform.tfstate`) contains the PSK — keep it local and secure
- PSK is generated once and shared across all tunnels
