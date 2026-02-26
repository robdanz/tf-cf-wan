# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Terraform project managing Cloudflare Magic WAN IPsec tunnels at scale. Creates 2 IPsec tunnels per site (primary + secondary, one to each Cloudflare Anycast IP) and generates an output CSV for CPE configuration.

## Commands

```bash
terraform init          # Download providers (cloudflare v5, random, local)
terraform validate      # Check syntax
terraform plan          # Preview changes
terraform apply         # Create/update tunnels, generate output/cpe-config.csv
terraform output -raw tunnel_psk   # Retrieve the shared PSK
terraform state show 'cloudflare_magic_wan_ipsec_tunnel.tunnels["<site>-pri"]'  # Inspect a tunnel
```

## Architecture

**Data flow:** `sites.csv` → `locals.tf` (parse/flatten/compute IPs) → `tunnels.tf` (create resources) → `outputs.tf` (generate cpe-config.csv)

### Core transformation in locals.tf

1. `csvdecode()` reads `sites.csv` into a site map keyed by `site_name`
2. Each site is flattened into 2 tunnel entries (`<site>-pri`, `<site>-sec`) via `flatten()`
3. `/31` inside addresses are allocated from the supernet using `cidrsubnet(supernet, 9, site_index * 2 + offset)` — the explicit `site_index` column (not row position) controls IP allocation so CSV reordering is safe
4. Within each /31: Cloudflare = `cidrhost(..., 0)` (even/lower), CPE = `cidrhost(..., 1)` (odd/upper)

### Resource pattern in tunnels.tf

Single `cloudflare_magic_wan_ipsec_tunnel` resource with `for_each = local.tunnel_definitions`. One `random_password` generates a shared PSK (`special = false` for CPE IKE compatibility, `length` controlled by `var.psk_length`).

The `health_check.target` attribute is a nested object — must be set as `{ saved = <ip> }`, not a plain string.

### Output in outputs.tf

`local_file` writes `output/cpe-config.csv` with sorted, deterministic rows.

The `fqdn_id` (Local IKE Identifier) is constructed as:
```
${tunnel.id}.${var.cloudflare_conduit_id}.ipsec.cloudflare.com
```
The Cloudflare provider does **not** expose a computed `fqdn_id` attribute — the format is `<tunnel-id>.<conduit-id>.ipsec.cloudflare.com` (not account ID).

## Variables and tfvars

All account-specific and tuneable values live in `terraform.tfvars` (gitignored). No account-specific defaults are hardcoded in `variables.tf`.

| Variable | Description |
|---|---|
| `cloudflare_api_token` | API token (Magic WAN: Edit + Account Settings: Read) |
| `cloudflare_account_id` | Cloudflare account ID |
| `cloudflare_conduit_id` | Conduit ID used in IKE FQDN identifier |
| `anycast_ip_1` | Primary Cloudflare Anycast IP (from account team) |
| `anycast_ip_2` | Secondary Cloudflare Anycast IP (from account team) |
| `tunnel_supernet` | Supernet for /31 inside address allocation |
| `health_check_enabled` | `true` / `false` |
| `health_check_direction` | `unidirectional` / `bidirectional` |
| `health_check_type` | `reply` / `request` |
| `health_check_rate` | `low` / `mid` / `high` |
| `replay_protection` | `true` / `false` — disable if CPE has IKE compatibility issues |

## Key Conventions

- Tunnel names: `{site_name}-{pri|sec}`
- Supernet `/22` + 9 bits = /31 → 512 subnets → max 256 sites
- `site_index` in CSV must be unique, starting from 0; controls IP allocation independent of row order
- All health check and IPsec settings are per-account variables, not per-site
- `terraform.tfvars`, `output/`, and `*.tfstate*` are gitignored (contain secrets)

## Cloudflare API Token Scopes

Account-level: **Magic WAN: Edit** + **Account Settings: Read**
