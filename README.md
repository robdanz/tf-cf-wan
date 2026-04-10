# tf-mwan

Terraform project to deploy Cloudflare Magic WAN IPsec tunnels at scale. You provide a CSV file listing your sites; this project creates two IPsec tunnels per site on Cloudflare (primary + secondary, one to each Anycast IP) and then configures the corresponding tunnels and VTIs directly on your Aruba EdgeConnect appliances.

**What gets created:**
- IPsec tunnels on Cloudflare (2 per site)
- `output/cpe-config.csv` — all tunnel parameters in one place
- `output/configure-tunnels.sh` — ready-to-run script that configures your EdgeConnect appliances (Mac/Linux)
- `output/remove-tunnels.sh` — rollback script that removes those tunnels and VTIs (Mac/Linux)

---

## Before You Start

You will need the following from your **Cloudflare account team** before you can proceed:

| Item | What it is |
|---|---|
| Cloudflare Account ID | Found in the Cloudflare dashboard URL or under Account Home → Settings |
| Cloudflare API Token | You create this — see instructions below |
| Conduit ID | Provided by your Cloudflare account team |
| Anycast IP 1 | Primary Magic WAN Anycast endpoint — provided by your account team |
| Anycast IP 2 | Secondary Magic WAN Anycast endpoint — provided by your account team |

### Creating a Cloudflare API Token

1. Log into the [Cloudflare dashboard](https://dash.cloudflare.com)
2. Click your profile icon (top right) → **My Profile** → **API Tokens**
3. Click **Create Token** → **Create Custom Token**
4. Give it a name (e.g., `magic-wan-deploy`)
5. Under **Permissions**, add:
   - **Account** | **Magic WAN** | **Edit**
   - **Account** | **Account Settings** | **Read**
6. Under **Account Resources**, select your account
7. Click **Continue to summary** → **Create Token**
8. **Copy the token now** — it will not be shown again

---

## Mac / Linux Deployment

### Prerequisites

- [Terraform](https://developer.hashicorp.com/terraform/install) >= 1.5
- `curl` and `jq` (for site discovery and configure scripts)

Install on Mac with Homebrew:
```bash
brew install terraform curl jq
```

Install on Ubuntu/Debian:
```bash
sudo apt-get install -y curl jq
sudo snap install terraform --classic
```

---

### Step 1 — Clone the repo and configure credentials

```bash
git clone https://github.com/robdanz/tf-cf-wan.git
cd tf-cf-wan
```

Copy the example configuration file and fill it in:

```bash
cp terraform.tfvars.example terraform.tfvars
```

Open `terraform.tfvars` in a text editor and fill in your values:

```hcl
# Cloudflare credentials — from your account team and the API token you created above
cloudflare_api_token  = "your-cloudflare-api-token"
cloudflare_account_id = "your-cloudflare-account-id"
cloudflare_conduit_id = "your-conduit-id"

# Anycast IPs — provided by your Cloudflare account team
anycast_ip_1 = "198.51.100.1"
anycast_ip_2 = "198.51.100.2"

# Tunnel inside address space
# A /22 gives you up to 256 sites. Use any private range that doesn't conflict
# with your existing network. The default below is a common starting point.
tunnel_supernet = "10.120.0.0/22"
```

> `terraform.tfvars` contains your API token. It is gitignored and must never be committed.

---

### Step 2 — Prepare sites.csv

`sites.csv` is the list of sites you want to deploy tunnels for. Each row is one site; two tunnels (primary + secondary) will be created for it.

#### Option A — Generate from Aruba Orchestrator (recommended)

If you have an Aruba Orchestrator, this script queries it automatically and builds the CSV for you.

First, set your Orchestrator API token. The easiest way is to export it as an environment variable so you don't have to type it repeatedly:

```bash
export ARUBA_API_TOKEN="your-orchestrator-api-token"
```

Then run the discovery script, replacing `10.0.0.100` with your Orchestrator's IP or hostname:

```bash
bash aruba/get_site_details.sh --orchestrator 10.0.0.100
```

This writes a proposed CSV to `sites.csv.proposed`. Review it before accepting:

```bash
cat sites.csv.proposed
```

If it looks correct, copy it to `sites.csv`:

```bash
cp sites.csv.proposed sites.csv
```

#### Option B — Create sites.csv manually

Create a file named `sites.csv` in the repo root with this format:

```csv
site_name,site_index,customer_gw_ip,ec_hostname
hq,0,203.0.113.10,10.0.0.1
chicago,1,198.51.100.20,10.0.0.2
denver,2,198.51.100.30,10.0.0.3
remote-nat,3,,10.0.0.4
```

| Column | Required | Description |
|---|---|---|
| `site_name` | yes | Short unique name for the site — becomes part of the tunnel name (e.g. `hq-pri`, `hq-sec`) |
| `site_index` | yes | Unique integer starting at 0 — determines which /31 IP pair is assigned; **never change or reuse once deployed** |
| `customer_gw_ip` | no | The CPE's public WAN IP. Leave blank if the CPE is behind NAT or has a dynamic IP |
| `ec_hostname` | yes | The management IP or hostname of the EdgeConnect appliance — the configure script connects to this address |

> **Tip for demo/testing without real hardware:** Run `bash aruba/demo_orchestrator.sh && cp sites.csv.proposed sites.csv` to generate a sample CSV with 10 simulated NAT'd sites.

---

### Step 3 — Deploy Cloudflare tunnels with Terraform

Initialize Terraform (downloads providers — only needed once per machine):

```bash
terraform init
```

Preview what will be created without making any changes:

```bash
terraform plan
```

Deploy:

```bash
terraform apply -parallelism=1
```

> **Why `-parallelism=1`?** The Cloudflare Magic WAN API uses a per-account write lock. If Terraform makes multiple requests at the same time it gets `429` (rate limit) errors. This flag makes it create resources one at a time.

When prompted, type `yes` to confirm. Terraform will create the tunnels on Cloudflare and generate the `output/` scripts.

After apply completes, retrieve the pre-shared key (you'll need this for the CPE):

```bash
terraform output -raw tunnel_psk
```

All tunnel parameters are also in `output/cpe-config.csv`.

---

### Step 4 — Configure EdgeConnect appliances

The `output/configure-tunnels.sh` script was generated by Terraform with the PSK and all tunnel parameters already embedded. Run it to push the IPsec tunnel config and create VTIs on each appliance.

You will be prompted once for the EdgeConnect admin password — it applies to all appliances.

**Static sites** (all sites have a `customer_gw_ip`):

```bash
bash output/configure-tunnels.sh --username admin
```

**NAT'd or dynamic sites** (any site has a blank `customer_gw_ip`): The script needs to look up the appliance's current WAN IP from the Orchestrator at run time.

Make sure `ARUBA_API_TOKEN` is set (from Step 2), then:

```bash
bash output/configure-tunnels.sh --username admin --orchestrator 10.0.0.100
```

If you didn't export `ARUBA_API_TOKEN`, pass the token directly:

```bash
bash output/configure-tunnels.sh --username admin \
  --orchestrator 10.0.0.100 \
  --orch-token "your-orchestrator-api-token"
```

**Run against specific appliances only** (useful for testing or partial deploys):

```bash
bash output/configure-tunnels.sh --username admin --sites 10.0.0.1,10.0.0.2
```

**Preview what would happen without making any changes:**

```bash
bash output/configure-tunnels.sh --dry-run
```

---

### Step 5 — Verify

List all tunnel names:

```bash
terraform output -json tunnel_details | jq -r 'to_entries[] | "\(.value.tunnel_name)  \(.value.cloudflare_endpoint)"'
```

Inspect a specific tunnel:

```bash
terraform state show 'cloudflare_magic_wan_ipsec_tunnel.tunnels["hq-pri"]'
```

---

### Step 6 — Rollback (if needed)

To remove tunnels and VTIs from the EdgeConnect appliances:

```bash
bash output/remove-tunnels.sh --dry-run        # preview
bash output/remove-tunnels.sh --username admin  # execute
```

> `output/remove-tunnels.sh` is self-contained — it does not need Terraform or the tfstate file. You can run it even after `terraform destroy`.

To destroy the Cloudflare resources:

```bash
terraform destroy -parallelism=1
```

> Run the remove script **before** `terraform destroy` if you want to use `output/remove-tunnels.sh`. Once you destroy, the Windows PS1 script (`aruba/remove_tunnels.ps1`) can still be used because it reads live terraform output — but `output/remove-tunnels.sh` will be gone.

---

---

## Windows Deployment

### Prerequisites

- [Terraform](https://developer.hashicorp.com/terraform/install) >= 1.5 — download the Windows AMD64 zip, extract `terraform.exe`, and place it somewhere in your `PATH` (e.g., `C:\Windows\System32` or a folder you add to PATH in System Settings)
- PowerShell 5.1 or later — already included in Windows 10 and 11
- No other tools required

**Verify Terraform is installed** by opening PowerShell and running:

```powershell
terraform version
```

You should see a version number. If you get "not recognized", Terraform is not in your PATH.

**Allow local scripts to run** (required once per machine):

```powershell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
```

---

### Step 1 — Clone the repo and configure credentials

Clone the repo using Git or download it as a ZIP from GitHub and extract it.

In PowerShell, navigate to the repo folder:

```powershell
cd C:\path\to\tf-cf-wan
```

Copy the example configuration file:

```powershell
Copy-Item terraform.tfvars.example terraform.tfvars
```

Open `terraform.tfvars` in Notepad or any text editor and fill in your values:

```hcl
# Cloudflare credentials — from your account team and the API token you created above
cloudflare_api_token  = "your-cloudflare-api-token"
cloudflare_account_id = "your-cloudflare-account-id"
cloudflare_conduit_id = "your-conduit-id"

# Anycast IPs — provided by your Cloudflare account team
anycast_ip_1 = "198.51.100.1"
anycast_ip_2 = "198.51.100.2"

# Tunnel inside address space
tunnel_supernet = "10.120.0.0/22"
```

> `terraform.tfvars` contains your API token. It is gitignored and must never be committed.

---

### Step 2 — Prepare sites.csv

Create `sites.csv` in the repo root manually (Orchestrator discovery requires bash — use a Mac/Linux machine or WSL if available):

```csv
site_name,site_index,customer_gw_ip,ec_hostname
hq,0,203.0.113.10,10.0.0.1
chicago,1,198.51.100.20,10.0.0.2
denver,2,198.51.100.30,10.0.0.3
remote-nat,3,,10.0.0.4
```

| Column | Required | Description |
|---|---|---|
| `site_name` | yes | Short unique name — becomes part of the tunnel name (e.g. `hq-pri`, `hq-sec`) |
| `site_index` | yes | Unique integer starting at 0 — determines IP allocation; **never change or reuse once deployed** |
| `customer_gw_ip` | no | CPE public WAN IP. Leave blank for NAT'd or dynamic CPE |
| `ec_hostname` | yes | Management IP or hostname of the EdgeConnect appliance |

---

### Step 3 — Deploy Cloudflare tunnels with Terraform

Initialize Terraform (downloads providers — only needed once):

```powershell
terraform init
```

Preview what will be created:

```powershell
terraform plan
```

Deploy:

```powershell
terraform apply -parallelism=1
```

> **Why `-parallelism=1`?** The Cloudflare Magic WAN API uses a per-account write lock. Without this flag, Terraform makes parallel requests and gets `429` rate limit errors.

Type `yes` when prompted to confirm. After apply, all tunnel parameters are in `output\cpe-config.csv`.

Retrieve the pre-shared key:

```powershell
terraform output -raw tunnel_psk
```

---

### Step 4 — Configure EdgeConnect appliances

The PowerShell script `aruba\configure_tunnels.ps1` reads tunnel data from Terraform and pushes the IPsec configuration and VTIs to each appliance. You will be prompted once for the EdgeConnect admin password.

Run from the repo root:

```powershell
.\aruba\configure_tunnels.ps1
```

**Common options:**

```powershell
# Preview what would happen without making changes:
.\aruba\configure_tunnels.ps1 -DryRun

# Specify a username other than admin:
.\aruba\configure_tunnels.ps1 -Username ecdeploy

# Run against specific appliances only:
.\aruba\configure_tunnels.ps1 -Sites "10.0.0.1,10.0.0.2"

# Enforce TLS certificate verification (only if appliances have valid certs):
.\aruba\configure_tunnels.ps1 -VerifySSL
```

**NAT'd or dynamic sites** (blank `customer_gw_ip`): Currently the PowerShell script does not support automatic WAN IP resolution from the Orchestrator. For NAT'd sites on Windows, either:
- Populate `customer_gw_ip` in `sites.csv` manually before running `terraform apply`, or
- Use the Mac/Linux path to run `output\configure-tunnels.sh` (e.g., via WSL)

---

### Step 5 — Verify

```powershell
terraform output -json tunnel_details
```

---

### Step 6 — Rollback (if needed)

Remove tunnels and VTIs from appliances:

```powershell
.\aruba\remove_tunnels.ps1 -DryRun    # preview
.\aruba\remove_tunnels.ps1            # execute
.\aruba\remove_tunnels.ps1 -Sites "10.0.0.1,10.0.0.2"  # specific appliances only
```

> The Windows remove script reads from `terraform output` and requires the tfstate file to be present. Run it **before** `terraform destroy`.

Destroy Cloudflare resources:

```powershell
terraform destroy -parallelism=1
```

---

---

## Reference

### Output: cpe-config.csv

Generated at `output/cpe-config.csv` (Mac/Linux) or `output\cpe-config.csv` (Windows) after `terraform apply`.

| Column | Description |
|---|---|
| `site_name` | Site identifier |
| `tunnel_label` | `pri` or `sec` |
| `tunnel_name` | Cloudflare tunnel name (e.g. `hq-pri`) |
| `tunnel_id` | Cloudflare tunnel UUID |
| `cloudflare_anycast_ip` | Cloudflare endpoint IP |
| `customer_gw_ip` | CPE WAN IP (blank for NAT'd sites) |
| `interface_address_cidr` | /31 tunnel subnet |
| `cf_inside_ip` | Cloudflare inner tunnel IP |
| `cpe_inside_ip` | IP to assign to CPE tunnel interface / VTI |
| `fqdn_id` | Local IKE identifier (`<tunnel-id>.<conduit-id>.ipsec.cloudflare.com`) |
| `psk` | Pre-shared key |

---

### IP Allocation

Inside addresses are carved from `tunnel_supernet` into /31 subnets. The `site_index` column controls which /31 is assigned to each site — it is independent of row order in the CSV.

```
site_index = i:
  pri tunnel → /31 subnet #(i × 2)
  sec tunnel → /31 subnet #(i × 2 + 1)

Within each /31:
  lower IP (even) → Cloudflare
  upper IP (odd)  → CPE / VTI
```

Example with `tunnel_supernet = 10.120.0.0/22` and `site_index = 0`:

```
pri:  10.120.0.0/31   CF: 10.120.0.0   CPE: 10.120.0.1
sec:  10.120.0.2/31   CF: 10.120.0.2   CPE: 10.120.0.3
```

A `/22` supernet supports up to 256 sites. Use a `/21` for up to 512.

---

### All Variables

| Variable | Required | Default | Description |
|---|---|---|---|
| `cloudflare_api_token` | yes | — | API token with Magic WAN: Edit + Account Settings: Read |
| `cloudflare_account_id` | yes | — | Your Cloudflare account ID |
| `cloudflare_conduit_id` | yes | — | Conduit ID for IKE FQDN (from account team) |
| `anycast_ip_1` | yes | — | Primary Anycast IP (from account team) |
| `anycast_ip_2` | yes | — | Secondary Anycast IP (from account team) |
| `tunnel_supernet` | yes | — | CIDR block for /31 inside address allocation |
| `psk_length` | no | `48` | Length of the generated pre-shared key |
| `health_check_enabled` | no | `true` | Enable tunnel health checks |
| `health_check_type` | no | `request` | `reply` or `request` |
| `health_check_direction` | no | `bidirectional` | `unidirectional` or `bidirectional` |
| `health_check_rate` | no | `mid` | `low`, `mid`, or `high` |
| `replay_protection` | no | `false` | IPsec anti-replay protection |

---

### Security Notes

| File | Contains | Status |
|---|---|---|
| `terraform.tfvars` | Cloudflare API token | gitignored — never commit |
| `output/` | PSK in plaintext | gitignored — treat as secret |
| `terraform.tfstate` | PSK in plaintext | gitignored — keep local and secure |
| `sites.csv` | Site topology and internal IPs | gitignored — never commit |

---

### Troubleshooting

**`429` errors during `terraform apply`**
Always include `-parallelism=1`. The Magic WAN API allows only one write operation at a time per account.

**`400` errors (code `1012`) during `terraform apply`**
Transient Cloudflare-side glitch. Re-run `terraform apply -parallelism=1` — it will pick up where it left off.

**Duplicate `/31` address error**
Happens when replacing all sites with a completely new `sites.csv`. Run `terraform destroy -parallelism=1` first, then `terraform apply -parallelism=1`. Terraform would otherwise try to create new tunnels before deleting old ones, and Cloudflare rejects duplicate inside addresses.

**NAT'd sites fail with "source IP required"**
Sites with a blank `customer_gw_ip` need a live WAN IP at configure time. On Mac/Linux, pass `--orchestrator` to `output/configure-tunnels.sh`. On Windows, populate `customer_gw_ip` manually or use WSL.

**EdgeConnect login returns `401 "You are not authenticated"`**
Check that the management IP in `ec_hostname` is reachable, the username/password is correct, and that HTTPS is accessible on the appliance. The scripts handle CSRF tokens automatically — this error usually means the login itself failed.

**PowerShell script blocked on first run**
Run `Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser` once in PowerShell, then retry.
