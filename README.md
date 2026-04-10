# tf-mwan

Terraform project to deploy Cloudflare Magic WAN IPsec tunnels at scale. For each site in `sites.csv`, it creates:

- 2 IPsec tunnels on Cloudflare (one to each Anycast IP — primary + secondary)
- `output/cpe-config.csv` — all tunnel parameters needed to configure the CPE
- `output/configure-tunnels.sh` — ready-to-run script to configure Aruba EdgeConnect appliances
- `output/remove-tunnels.sh` — rollback script to remove those tunnels

Tunnel inside addresses are allocated deterministically from a supernet using the `site_index` column — CSV row order does not affect IP assignment.

---

## Prerequisites

### Mac / Linux

| Tool | Purpose |
|---|---|
| [Terraform](https://developer.hashicorp.com/terraform/install) >= 1.5 | Creates Cloudflare resources |
| `curl` | ECOS API calls in shell scripts |
| `jq` | JSON parsing in shell scripts |

### Windows

| Tool | Purpose |
|---|---|
| [Terraform](https://developer.hashicorp.com/terraform/install) >= 1.5 | Creates Cloudflare resources; must be in `PATH` |
| PowerShell 5.1+ | Included in Windows 10/11 |

Windows scripts use only `Invoke-RestMethod` (built-in) and `terraform` — no extra tools required.

---

## Setup

### 1. Create terraform.tfvars

```bash
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars` with values from your Cloudflare account team:

```hcl
cloudflare_api_token  = "your-api-token"       # Magic WAN: Edit + Account Settings: Read
cloudflare_account_id = "your-account-id"
cloudflare_conduit_id = "your-conduit-id"       # from your account team

anycast_ip_1    = "198.51.100.1"                # Primary Anycast IP (from account team)
anycast_ip_2    = "198.51.100.2"                # Secondary Anycast IP (from account team)
tunnel_supernet = "10.120.0.0/22"               # /22 → 512 /31 subnets → up to 256 sites
```

`terraform.tfvars` is gitignored — never commit it.

### 2. Prepare sites.csv

`sites.csv` drives everything. Each row is one physical site; two tunnels are created per site.

| Column | Required | Description |
|---|---|---|
| `site_name` | yes | Unique site identifier — used as tunnel name prefix (`{site_name}-pri`, `{site_name}-sec`) |
| `site_index` | yes | Unique integer (0-based) — controls /31 IP allocation; never reuse or change once applied |
| `customer_gw_ip` | no | CPE WAN IP (IPsec endpoint). Leave blank for NAT'd or dynamic CPE |
| `ec_hostname` | yes | EdgeConnect management IP used by configure scripts |

Example:

```csv
site_name,site_index,customer_gw_ip,ec_hostname
hq,0,203.0.113.10,10.0.0.1
chicago,1,198.51.100.20,10.0.0.2
denver,2,198.51.100.30,10.0.0.3
remote-nat,3,,10.0.0.4
```

> **NAT'd / dynamic CPE:** When `customer_gw_ip` is blank, no fixed remote IP is set on the Cloudflare tunnel. The CPE must initiate IKE and use the `fqdn_id` value from `cpe-config.csv` as its local IKE identifier. `configure-tunnels.sh` resolves the live WAN IP from the Orchestrator at run time (requires `--orchestrator`).

> **`site_index` is permanent.** It controls IP allocation. Changing or reusing an index after `terraform apply` will cause Terraform to destroy and recreate tunnels at those IPs.

---

## End-to-End Workflow

### Step 1 — Discover sites (optional)

If you have an Aruba Orchestrator, generate `sites.csv` automatically:

```bash
# Mac / Linux
export ARUBA_API_TOKEN="your-orchestrator-api-token"
bash aruba/get_site_details.sh --orchestrator 10.0.0.100

# Review and approve the proposed CSV
cat sites.csv.proposed
cp sites.csv.proposed sites.csv
```

Or for a demo with 10 simulated NAT'd sites:

```bash
bash aruba/demo_orchestrator.sh
cp sites.csv.proposed sites.csv
```

If you're not using Aruba Orchestrator, create `sites.csv` manually using the format above.

---

### Step 2 — Create Cloudflare tunnels

```bash
terraform init       # first time only
terraform plan
terraform apply -parallelism=1
```

> **`-parallelism=1` is required.** The Cloudflare Magic WAN API uses a per-account write lock. Parallel requests cause `429` errors.

On success, Terraform creates:
- IPsec tunnels on Cloudflare (2 per site)
- `output/cpe-config.csv` — all tunnel parameters
- `output/configure-tunnels.sh` — pre-built ECOS configuration script
- `output/remove-tunnels.sh` — pre-built ECOS rollback script

Retrieve the PSK:

```bash
terraform output -raw tunnel_psk
```

---

### Step 3 — Configure EdgeConnect appliances

Two options depending on your platform. Both read tunnel data from Terraform output and configure each appliance via the ECOS REST API. Password is prompted once for all appliances.

#### Option A — Use the generated script (Mac / Linux, recommended)

`output/configure-tunnels.sh` has the PSK and all tunnel parameters embedded. It connects directly to each appliance, creates the IPsec tunnels, and creates the VTIs.

```bash
# Static sites (customer_gw_ip populated):
bash output/configure-tunnels.sh --username admin

# NAT'd/dynamic sites (blank customer_gw_ip) — Orchestrator needed for WAN IP lookup:
bash output/configure-tunnels.sh --username admin \
  --orchestrator 10.0.0.100 --orch-token "$ARUBA_API_TOKEN"

# Limit to specific appliances:
bash output/configure-tunnels.sh --username admin --sites 10.0.0.1,10.0.0.2

# Dry run (preview only):
bash output/configure-tunnels.sh --dry-run
```

#### Option B — Use the standalone script (Mac / Linux)

Reads live terraform output directly. Useful when running from the repo rather than the generated `output/` files.

```bash
bash aruba/configure_tunnels.sh --username admin
bash aruba/configure_tunnels.sh --username admin --sites hq,chicago
bash aruba/configure_tunnels.sh --dry-run
```

#### Option C — PowerShell (Windows)

Reads live terraform output. Terraform must be in `PATH`.

```powershell
# From the repo root or aruba/ directory:
.\aruba\configure_tunnels.ps1
.\aruba\configure_tunnels.ps1 -Sites "hq,chicago"
.\aruba\configure_tunnels.ps1 -DryRun
.\aruba\configure_tunnels.ps1 -Username admin -VerifySSL
```

Password is prompted securely using `Read-Host -AsSecureString`.

---

### Step 4 — Verify

Check tunnel state on Cloudflare:

```bash
terraform output -json tunnel_details | jq '.[].tunnel_name'
```

Check a specific tunnel:

```bash
terraform state show 'cloudflare_magic_wan_ipsec_tunnel.tunnels["hq-pri"]'
```

---

### Step 5 — Rollback EdgeConnect appliances (if needed)

Removes IPsec tunnels and VTIs from the appliances. Self-contained — works independently of terraform state.

```bash
# Mac / Linux (generated script — no terraform required):
bash output/remove-tunnels.sh --dry-run          # preview
bash output/remove-tunnels.sh --username admin   # execute

# Mac / Linux (standalone — reads terraform output):
bash aruba/remove_tunnels.sh --dry-run
bash aruba/remove_tunnels.sh --username admin

# Windows:
.\aruba\remove_tunnels.ps1 -DryRun
.\aruba\remove_tunnels.ps1
.\aruba\remove_tunnels.ps1 -Sites "hq,chicago"
```

---

### Step 6 — Destroy Cloudflare resources

```bash
terraform destroy -parallelism=1
```

> Run the remove script **before** `terraform destroy` if you need the generated `output/remove-tunnels.sh` (it embeds tunnel names from state). After destroy, use `aruba/remove_tunnels.sh` or `aruba/remove_tunnels.ps1` instead — they derive names from terraform output.

---

## IP Allocation

Inside addresses are allocated from `tunnel_supernet` (default `10.120.0.0/22`) using 9 additional bits, yielding /31 subnets:

```
site_index = i
  pri tunnel: cidrsubnet(supernet, 9, i * 2)
  sec tunnel: cidrsubnet(supernet, 9, i * 2 + 1)

Within each /31:
  Cloudflare = lower (even) IP
  CPE        = upper (odd)  IP
```

Example for `site_index = 0` with `tunnel_supernet = 10.120.0.0/22`:

```
pri:  10.120.0.0/31   CF: 10.120.0.0   CPE: 10.120.0.1
sec:  10.120.0.2/31   CF: 10.120.0.2   CPE: 10.120.0.3
```

A `/22` supernet supports up to 256 sites. Use a larger supernet (e.g., `/21`) if you need more.

---

## Output: cpe-config.csv

Generated at `output/cpe-config.csv` after `terraform apply`.

| Column | Description |
|---|---|
| `site_name` | Site identifier |
| `tunnel_label` | `pri` or `sec` |
| `tunnel_name` | Cloudflare tunnel name |
| `tunnel_id` | Cloudflare tunnel UUID |
| `cloudflare_anycast_ip` | Cloudflare Anycast endpoint IP |
| `customer_gw_ip` | CPE WAN IP (blank for NAT'd sites) |
| `interface_address_cidr` | /31 tunnel subnet |
| `cf_inside_ip` | Cloudflare inner tunnel IP |
| `cpe_inside_ip` | IP to assign to CPE tunnel interface / VTI |
| `fqdn_id` | Local IKE identifier (`<tunnel-id>.<conduit-id>.ipsec.cloudflare.com`) |
| `psk` | Pre-shared key |

---

## Variables

All required values go in `terraform.tfvars` (gitignored). No defaults are hardcoded.

| Variable | Required | Default | Description |
|---|---|---|---|
| `cloudflare_api_token` | yes | — | Magic WAN: Edit + Account Settings: Read |
| `cloudflare_account_id` | yes | — | Cloudflare account ID |
| `cloudflare_conduit_id` | yes | — | Conduit ID for IKE FQDN identifier (from account team) |
| `anycast_ip_1` | yes | — | Primary Anycast IP (from account team) |
| `anycast_ip_2` | yes | — | Secondary Anycast IP (from account team) |
| `tunnel_supernet` | yes | — | Supernet for /31 allocation (e.g. `10.120.0.0/22`) |
| `psk_length` | no | `48` | PSK length in characters |
| `health_check_enabled` | no | `true` | Enable tunnel health checks |
| `health_check_type` | no | `request` | `reply` or `request` |
| `health_check_direction` | no | `bidirectional` | `unidirectional` or `bidirectional` |
| `health_check_rate` | no | `mid` | `low`, `mid`, or `high` |
| `replay_protection` | no | `false` | IPsec anti-replay (disable if CPE has IKE compatibility issues) |

---

## Script Reference

### Site discovery

| Script | Platform | Description |
|---|---|---|
| `aruba/get_site_details.sh` | Mac/Linux | Query Orchestrator → generates `sites.csv.proposed` |
| `aruba/demo_orchestrator.sh` | Mac/Linux | Simulate Orchestrator with 10 NAT'd sites (demo/testing) |

```bash
bash aruba/get_site_details.sh --orchestrator HOST [--sites HOST1,HOST2]
```

### Configure tunnels

| Script | Platform | Description |
|---|---|---|
| `output/configure-tunnels.sh` | Mac/Linux | Auto-generated; PSK embedded; recommended for production |
| `aruba/configure_tunnels.sh` | Mac/Linux | Reads live terraform output; useful during development |
| `aruba/configure_tunnels.ps1` | Windows | PowerShell equivalent of above |

### Remove tunnels

| Script | Platform | Description |
|---|---|---|
| `output/remove-tunnels.sh` | Mac/Linux | Auto-generated; self-contained; works after `terraform destroy` |
| `aruba/remove_tunnels.sh` | Mac/Linux | Reads live terraform output |
| `aruba/remove_tunnels.ps1` | Windows | PowerShell equivalent of above |

### Common flags

| Flag | Shell scripts | PowerShell | Description |
|---|---|---|---|
| Username | `--username USER` | `-Username USER` | EdgeConnect username (default: `admin`) |
| Password | `--password PASS` | `-Password PASS` | Prompted if omitted |
| Site filter | `--sites H1,H2` | `-Sites "H1,H2"` | Filter by appliance IP/hostname |
| Dry run | `--dry-run` | `-DryRun` | Preview without making changes |
| TLS verify | `--verify-ssl` | `-VerifySSL` | Enforce cert verification (off by default for IP-based access) |

---

## Aruba Orchestrator API Token

Required only for `get_site_details.sh` and for NAT'd sites at configure time.

```bash
export ARUBA_API_TOKEN="your-orchestrator-token"
```

Or pass it explicitly with `--orch-token TOKEN`. The token needs **Site Admin, read-only** on the Orchestrator.

---

## Security Notes

| File | Contains | Disposition |
|---|---|---|
| `terraform.tfvars` | API token | gitignored — never commit |
| `output/` | PSK in plaintext | gitignored — treat as secret |
| `terraform.tfstate` | PSK in plaintext | keep local and secure; do not commit |
| `sites.csv` | Site topology | gitignored — may contain internal IPs |

---

## Troubleshooting

**`429` errors during `terraform apply`**
Always use `-parallelism=1`. The Magic WAN API uses a per-account write lock.

**`400` errors (code `1012`) during apply**
Transient Cloudflare infrastructure glitch. Re-run `terraform apply -parallelism=1`.

**Duplicate `/31` address error on replace**
When replacing all sites with a new `sites.csv`, run `terraform destroy -parallelism=1` first. Terraform creates before destroying, and Cloudflare rejects duplicate inside addresses.

**NAT'd site requires `--orchestrator`**
Sites with a blank `customer_gw_ip` need the Orchestrator to resolve the live WAN IP at configure time. Pass `--orchestrator HOST` to `configure-tunnels.sh` or `configure_tunnels.sh`.

**`401 "You are not authenticated"` from ECOS**
The ECOS API requires both a session cookie and an `X-XSRF-TOKEN` header. The scripts handle this automatically. If you see this error, check that the appliance firmware is accessible and the login succeeded (HTTP 200).
