# Mac / Linux Deployment Guide — From Scratch

This guide walks you through deploying Cloudflare Magic WAN IPsec tunnels and configuring your Aruba EdgeConnect appliances from a Mac or Linux machine with no prior tools installed.

**What you will do:**
1. Install the required tools (Terraform, curl, jq) — one-time setup
2. Download this project
3. Configure your Cloudflare credentials
4. Discover your sites from Aruba Orchestrator → `sites.csv`
5. Create the Cloudflare tunnels with Terraform
6. Push the IPsec configuration to your EdgeConnect appliances

**Time required:** 30–60 minutes for first deployment, depending on the number of sites.

---

## Before You Start

Collect the following from your **Cloudflare account team** before beginning. You cannot proceed without these:

| Item | Where it comes from |
|---|---|
| Cloudflare Account ID | Cloudflare dashboard → Account Home → Settings, or visible in the dashboard URL |
| Cloudflare API Token | You create this (instructions below) |
| Conduit ID | Provided by your Cloudflare account team |
| Anycast IP 1 | Provided by your Cloudflare account team — primary Magic WAN endpoint |
| Anycast IP 2 | Provided by your Cloudflare account team — secondary Magic WAN endpoint |

You will also need:
- Network access to your EdgeConnect appliances (management IPs reachable from your machine)
- The EdgeConnect admin username and password
- A list of your sites with their WAN IPs and EdgeConnect management IPs (or an Aruba Orchestrator to generate this automatically)

### Creating a Cloudflare API Token

1. Log into [https://dash.cloudflare.com](https://dash.cloudflare.com)
2. Click your profile icon (top-right corner) → **My Profile** → **API Tokens**
3. Click **Create Token** → **Create Custom Token**
4. Name it something like `magic-wan-deploy`
5. Under **Permissions**, add two entries:
   - **Account** | **Magic WAN** | **Edit**
   - **Account** | **Account Settings** | **Read**
6. Under **Account Resources**, select your specific account
7. Click **Continue to summary** → **Create Token**
8. **Copy the token immediately** — it is shown only once

---

## Part 1 — Install Required Tools

### 1.1 — Mac (Homebrew)

[Homebrew](https://brew.sh) is the easiest way to install all required tools. If you don't have it:

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

Then install Terraform, curl, and jq:

```bash
brew install terraform curl jq
```

Verify:

```bash
terraform version
curl --version
jq --version
```

You should see version numbers for all three. If `terraform` is not found after install, close and reopen your terminal.

---

### 1.2 — Linux (Ubuntu / Debian)

```bash
sudo apt-get update && sudo apt-get install -y curl jq
sudo snap install terraform --classic
```

If `snap` is not available on your distribution, install Terraform manually:

```bash
TERRAFORM_VERSION=$(curl -s https://checkpoint-api.hashicorp.com/v1/check/terraform | jq -r .current_version)
curl -Lo /tmp/terraform.zip "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_amd64.zip"
sudo unzip -o /tmp/terraform.zip -d /usr/local/bin
rm /tmp/terraform.zip
```

Verify:

```bash
terraform version
curl --version
jq --version
```

---

### 1.3 — Linux (RHEL / CentOS / Fedora)

```bash
sudo yum install -y curl jq unzip
TERRAFORM_VERSION=$(curl -s https://checkpoint-api.hashicorp.com/v1/check/terraform | jq -r .current_version)
curl -Lo /tmp/terraform.zip "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_amd64.zip"
sudo unzip -o /tmp/terraform.zip -d /usr/local/bin
rm /tmp/terraform.zip
```

---

## Part 2 — Download the Project

Choose a location for the project files, then clone the repository:

```bash
cd ~/Documents    # or wherever you prefer
git clone https://github.com/robdanz/tf-cf-wan.git
cd tf-cf-wan
```

> **No internet access to GitHub from your machine?** Download the ZIP instead: go to the GitHub repository page, click the green **Code** button → **Download ZIP**. Extract the ZIP and `cd` into the folder.

---

## Part 3 — Configure Your Credentials

### 3.1 — Create terraform.tfvars

`terraform.tfvars` holds your Cloudflare credentials and settings. It is gitignored and must never be committed — it contains your API token.

```bash
cp terraform.tfvars.example terraform.tfvars
```

### 3.2 — Edit terraform.tfvars

Open it in any text editor:

```bash
nano terraform.tfvars    # or: vi terraform.tfvars, code terraform.tfvars, etc.
```

Fill in your values:

```hcl
# Cloudflare credentials
cloudflare_api_token  = "paste-your-api-token-here"
cloudflare_account_id = "paste-your-account-id-here"
cloudflare_conduit_id = "paste-your-conduit-id-here"

# Anycast IPs — from your Cloudflare account team
anycast_ip_1 = "198.51.100.1"    # replace with your actual Anycast IP 1
anycast_ip_2 = "198.51.100.2"    # replace with your actual Anycast IP 2

# Tunnel inside address space
# A /22 supports up to 256 sites. Pick any private range that doesn't
# conflict with your existing networks.
tunnel_supernet = "10.120.0.0/22"
```

The remaining lines (health check settings, replay protection) can be left at their defaults for now.

Save and close.

> **Important:** The `tunnel_supernet` range is used for tunnel inside addresses (VTI IPs) — not for your LAN subnets. It should be a `/22` or larger private range that is not in use anywhere in your network.

---

## Part 4 — Discover Sites and Prepare sites.csv

`sites.csv` tells Terraform which sites to build tunnels for. Each row = one site = two Cloudflare tunnels (primary + secondary).

### Option A — Generate from Aruba Orchestrator (recommended)

If you have an Aruba Orchestrator, `aruba/get_site_details.sh` queries it automatically and builds the CSV for you. This is the recommended path — it discovers all appliances, their WAN IPs, and picks the right management IP for each appliance type.

#### 4A.1 — Get your Orchestrator API token

The script authenticates with an Orchestrator API token (not username/password). A **Site Admin, read-only** role is sufficient — the script only reads data.

Obtain a token from your Orchestrator administrator, or create one:
1. Log into the Orchestrator web UI
2. Navigate to **Administration** → **API Tokens** (exact path varies by firmware version)
3. Create a new token with read-only access
4. Copy the token value

#### 4A.2 — Set your token as an environment variable

```bash
export ARUBA_API_TOKEN="paste-your-token-here"
```

> To make this permanent, add the line to your shell profile (`~/.zshrc` on Mac, `~/.bashrc` or `~/.bash_profile` on Linux), then run `source ~/.zshrc` (or `~/.bashrc`).

#### 4A.3 — Run the discovery script

Replace `10.0.0.100` with your Orchestrator's IP or hostname:

```bash
bash aruba/get_site_details.sh --orchestrator 10.0.0.100
```

Or pass the token directly if you haven't set the environment variable:

```bash
bash aruba/get_site_details.sh --orchestrator 10.0.0.100 --orch-token "your-token-here"
```

The script connects to the Orchestrator, queries every appliance for interface state and subnet data, prints a summary to the screen, and writes `sites.csv.proposed` to the repo root.

**Example output:**

```
INFO  Fetching appliance list from 10.0.0.100...
INFO  Found 3 appliance(s)
INFO  Processing HQ-EC (nePk: NePk001)...
INFO  Processing Chicago-EC (nePk: NePk002)...
INFO  Processing Denver-EC (nePk: NePk003)...

============================================================
 SITE DETAILS SUMMARY
============================================================
Site: HQ-EC  api_target=10.1.0.10  [mgmt0]
  customer_gw_ip:    203.0.113.10
  WAN interfaces:
    wan0: 203.0.113.10/30  (public: 203.0.113.10)
  LAN subnets (advertised/local):
    10.10.0.0/24

...
============================================================

INFO  Written sites.csv.proposed (3 sites)
```

#### 4A.4 — Review sites.csv.proposed

```bash
cat sites.csv.proposed
```

Check each row:
- **`site_name`** — auto-generated from the appliance hostname. Edit if it's unclear or too long.
- **`customer_gw_ip`** — the appliance's public WAN IP. If blank, the site is treated as NAT'd/dynamic. Verify this is intentional. If an appliance has multiple WAN interfaces, the script picks the first one with a public IP — edit if the wrong IP was chosen.
- **`ec_hostname`** — the management IP the configure script will connect to. The script sets this to the `mgmt0` IP for virtual appliances and the Orchestrator management IP for hardware appliances. Replace with a DNS name if you prefer.
- **`site_index`** — auto-assigned in alphabetical order starting from 0. **Do not change or reuse these once a site has been deployed** — they control IP allocation and changing them forces tunnel recreation.

#### 4A.5 — Accept the proposed CSV

Once you're satisfied with the contents:

```bash
cp sites.csv.proposed sites.csv
```

Proceed to Part 5.

---

### Option B — Create sites.csv Manually

If you don't have an Orchestrator, create `sites.csv` by hand:

```bash
cat > sites.csv << 'EOF'
site_name,site_index,customer_gw_ip,ec_hostname
hq,0,203.0.113.10,10.0.0.1
chicago,1,198.51.100.20,10.0.0.2
denver,2,198.51.100.30,10.0.0.3
remote-nat,3,,10.0.0.4
EOF
```

**Column reference:**

| Column | Required | Description |
|---|---|---|
| `site_name` | Yes | Short unique name for the site. Becomes part of tunnel names: `hq-pri`, `hq-sec`. Letters, numbers, and hyphens only — no spaces. |
| `site_index` | Yes | Unique integer starting at 0. **Controls which IP block is assigned to this site — never change or reuse once deployed.** Adding new sites: use the next available number. |
| `customer_gw_ip` | No | The EdgeConnect appliance's public WAN IP. Leave blank if the appliance is behind NAT or has a dynamic IP. |
| `ec_hostname` | Yes | The management IP address (or hostname) of the EdgeConnect appliance — what the configure script connects to. |

**Finding `ec_hostname`:**
- For **EC-V (virtual) appliances**: use the `mgmt0` interface IP.
- For **hardware appliances (EC-S, EC-10104)**: use the Orchestrator's management IP for that appliance (`mgmt0` has no IP on hardware).

**NAT'd or dynamic sites (`customer_gw_ip` left blank):** You will need `--orchestrator` when running `configure-tunnels.sh` so the script can resolve each appliance's current WAN IP at run time. See Part 6.

> **Tip for demo/testing without real hardware:** Run `bash aruba/demo_orchestrator.sh && cp sites.csv.proposed sites.csv` to generate a sample CSV with 10 simulated NAT'd sites.

---

## Part 5 — Deploy Cloudflare Tunnels with Terraform

All commands below are run from the repo root.

Verify you are in the right directory:

```bash
pwd
# Should show: /path/to/tf-cf-wan
```

### 5.1 — Initialize Terraform

Downloads the Cloudflare provider plugin. Only needed once per machine (or after deleting the `.terraform` folder).

```bash
terraform init
```

You should see output ending with:
```
Terraform has been successfully initialized!
```

---

### 5.2 — Preview What Will Be Created

```bash
terraform plan
```

This does not make any changes — it shows exactly what Terraform would create. Review the output. You should see one `cloudflare_magic_wan_ipsec_tunnel` resource per site label (two per site: `hq-pri`, `hq-sec`, etc.) and corresponding static routes.

If you see errors here, they usually mean:
- A value in `terraform.tfvars` is missing or wrong
- `sites.csv` has a formatting issue (check for extra spaces, wrong column names)
- The Cloudflare API token doesn't have the right permissions

---

### 5.3 — Deploy

```bash
terraform apply -parallelism=1
```

> **Why `-parallelism=1`?** The Cloudflare Magic WAN API allows only one write operation at a time per account. Without this flag, Terraform makes parallel requests and receives `429` (rate-limited) errors. This flag makes it process resources one at a time.

Terraform will display the plan one more time and ask:

```
Do you want to perform these actions?
  Terraform will perform the actions described above.
  Only 'yes' will be accepted to approve.

  Enter a value:
```

Type `yes` and press Enter.

Terraform creates the tunnels sequentially — with many sites this may take several minutes. When complete:

```
Apply complete! Resources: X added, 0 changed, 0 destroyed.
```

This also writes four files to the `output/` folder:
- `output/cpe-config.csv` — all tunnel parameters in one place (IPs, IDs, PSK)
- `output/configure-tunnels.sh` — ready-to-run script to configure EdgeConnect appliances (PSK embedded)
- `output/remove-tunnels.sh` — script to remove tunnels and VTIs (self-contained)
- `output/configure-tunnels.ps1` — Windows PowerShell version of the configure script
- `output/remove-tunnels.ps1` — Windows PowerShell version of the remove script

---

### 5.4 — Retrieve the Pre-Shared Key

The PSK was randomly generated and is embedded in the configure script. Retrieve it:

```bash
terraform output -raw tunnel_psk
```

Save this value somewhere secure — you may need it for manual CPE configuration or troubleshooting. It is also visible in `output/cpe-config.csv`.

---

### 5.5 — Review Tunnel Details

All tunnel parameters (IPs, tunnel IDs, FQDN identifiers) are in `output/cpe-config.csv`:

```bash
cat output/cpe-config.csv
```

To see the full Terraform output:

```bash
terraform output -json tunnel_details
```

---

## Part 6 — Configure EdgeConnect Appliances

`output/configure-tunnels.sh` is generated by `terraform apply` and pushes the IPsec tunnel configuration and VTIs to each EdgeConnect appliance via the ECOS REST API. The PSK and all tunnel parameters are embedded — no Terraform dependency at run time.

**Prerequisites before running:**
- `terraform apply` must have completed successfully (this generates `output/configure-tunnels.sh`)
- Your machine must be able to reach each appliance's management IP (the `ec_hostname` values from `sites.csv`)
- You need the EdgeConnect admin credentials
- For NAT'd/dynamic sites: network access to the Orchestrator and `ARUBA_API_TOKEN` set

### 6.1 — Dry Run First (Recommended)

Always preview before making changes:

```bash
bash output/configure-tunnels.sh --dry-run
```

This prints what it would do — which appliances it would connect to, which tunnels it would create — without making any API calls. Verify the site list and tunnel names look correct.

---

### 6.2 — Run the Configuration

**Static sites** (all sites have a `customer_gw_ip`):

```bash
bash output/configure-tunnels.sh --username admin
```

**NAT'd or dynamic sites** (any site has a blank `customer_gw_ip`): The script resolves each appliance's current WAN IP from the Orchestrator at run time.

Make sure `ARUBA_API_TOKEN` is exported (from Step 4A.2), then:

```bash
bash output/configure-tunnels.sh --username admin --orchestrator 10.0.0.100
```

Or pass the token directly:

```bash
bash output/configure-tunnels.sh --username admin \
  --orchestrator 10.0.0.100 \
  --orch-token "your-orchestrator-api-token"
```

You will be prompted once for the EdgeConnect admin password. The same password is used for all appliances.

The script will log into each appliance, create both IPsec tunnels (`site-pri` and `site-sec`), and create the corresponding VTIs. Progress is printed as it runs:

```
INFO  --- Site: hq  appliance: 10.0.0.1 ---
INFO    Logged in OK
INFO    Creating hq-pri...
INFO      Tunnel OK (HTTP 200)
INFO      VTI OK (vti110)
INFO    Creating hq-sec...
INFO      Tunnel OK (HTTP 200)
INFO      VTI OK (vti111)
INFO    Logged out
```

The script is **idempotent** — if a tunnel already exists on the appliance, it skips creation and moves on. Safe to re-run.

---

### 6.3 — Common Options

**Different username:**
```bash
bash output/configure-tunnels.sh --username ecdeploy
```

**Specific appliances only** (useful for testing or partial deployment):
```bash
bash output/configure-tunnels.sh --username admin --sites 10.0.0.1,10.0.0.2
```

Note: `--sites` filters by **appliance IP/hostname** (the `ec_hostname` values), not by site name.

**Supply password non-interactively** (for automation):
```bash
bash output/configure-tunnels.sh --username admin --password "yourpass"
```

**If your appliances have valid TLS certificates** (uncommon — most use self-signed):
```bash
bash output/configure-tunnels.sh --username admin --verify-ssl
```

By default, the script skips TLS certificate verification — this is intentional since EdgeConnect appliances typically use self-signed certificates when accessed by IP.

---

### 6.4 — Verify on the Appliance

After the script completes, log into an EdgeConnect appliance and confirm:
- **Configuration → Passthrough Tunnels** — you should see `site-pri` and `site-sec` entries
- **Configuration → Virtual Interfaces (VTI)** — you should see VTIs for each tunnel with the correct inside IP assigned

On the Cloudflare side, the tunnel health checks should show green within a few minutes of the tunnels coming up.

---

## Part 7 — Rollback (If Needed)

### 7.1 — Remove Tunnels and VTIs from Appliances

```bash
# Preview first:
bash output/remove-tunnels.sh --dry-run

# Execute:
bash output/remove-tunnels.sh --username admin
```

The remove script is generated by `terraform apply` with all tunnel names embedded — it does not require Terraform or the state file at run time. It will:
1. Log into each appliance
2. Find and delete the passthrough tunnels by name
3. Find and delete the VTIs associated with those tunnels

**Specific appliances only:**
```bash
bash output/remove-tunnels.sh --username admin --sites 10.0.0.1,10.0.0.2
```

> `output/remove-tunnels.sh` is self-contained — you can run it before or after `terraform destroy`.

---

### 7.2 — Destroy Cloudflare Resources

After (or instead of) removing the appliance config:

```bash
terraform destroy -parallelism=1
```

Type `yes` when prompted. This deletes all Cloudflare tunnels and static routes created by this project.

---

## Part 8 — Day 2 Operations

### Adding New Sites

1. Add new rows to `sites.csv`. Use the next available `site_index` (never reuse or change existing ones).
2. Run `terraform apply -parallelism=1` — only new resources will be created, and the `output/` scripts are regenerated.
3. Run `bash output/configure-tunnels.sh --username admin --sites new-appliance-ip` to configure only the new appliances.

### Removing Sites

1. Run `bash output/remove-tunnels.sh --username admin --sites appliance-ip` to clean up the appliance first.
2. Delete the site's row from `sites.csv`.
3. Run `terraform apply -parallelism=1` — Terraform will destroy the tunnels for that site.

### Updating After a Terraform Change

If you change `terraform.tfvars` settings (health check direction, replay protection, etc.):
1. Run `terraform apply -parallelism=1`
2. No action is needed on the appliances for most Cloudflare-side changes.

### Getting the Current PSK

```bash
terraform output -raw tunnel_psk
```

---

## Troubleshooting

### get_site_details.sh returns "curl: Could not resolve host"
- Verify the Orchestrator is reachable: `curl -k -o /dev/null -w "%{http_code}" https://10.0.0.100/gms/rest/appliance -H "X-Auth-Token: $ARUBA_API_TOKEN"`
- Verify your API token is correct — a wrong token returns `401`
- Verify the token has at least **Site Admin, read-only** access

### get_site_details.sh shows all sites with blank customer_gw_ip
All appliances are behind NAT or have dynamic WAN IPs. Check the WAN interfaces section of the summary — if no public IPs appear, the Orchestrator may not have current interface state. Try refreshing it from the Orchestrator UI, or fill in `customer_gw_ip` manually in `sites.csv`.

### "terraform: command not found"
Terraform is not in your `PATH`. On Mac, if you installed via Homebrew: `brew doctor` and check for PATH issues. On Linux: verify `/usr/local/bin` is in your `PATH` with `echo $PATH`.

### `terraform apply` returns 429 errors
You forgot `-parallelism=1`. The Cloudflare Magic WAN API only allows one write at a time. Always use:
```bash
terraform apply -parallelism=1
```

### `terraform apply` returns 400 errors (code 1012)
Transient Cloudflare infrastructure glitch. Just re-run:
```bash
terraform apply -parallelism=1
```
Terraform picks up where it left off and only retries the failed resources.

### "Duplicate /31 address" error during apply
Happens when replacing all sites with a completely new `sites.csv` (new `site_index` values). Terraform tries to create new tunnels before destroying old ones, and Cloudflare rejects duplicate inside addresses. Fix: destroy first, then apply.
```bash
terraform destroy -parallelism=1
terraform apply -parallelism=1
```

### configure-tunnels.sh returns "Login failed"
- Verify the management IP in `ec_hostname` is reachable: `curl -k -o /dev/null -w "%{http_code}" https://10.0.0.1/rest/json/login`
- Verify the username and password are correct
- Verify HTTPS (port 443) is accessible on the appliance

### configure-tunnels.sh returns "orchestrator required" for a NAT'd site
Pass `--orchestrator HOST` to `configure-tunnels.sh`. The Orchestrator is needed to resolve the appliance's current WAN IP at run time for sites where `customer_gw_ip` is blank.

### Tunnel exists on appliance but not on Cloudflare (or vice versa)
`configure-tunnels.sh` is idempotent on the appliance side (skips existing tunnels). If a tunnel is stuck in a partial state:
1. Run `bash output/remove-tunnels.sh --username admin` to clean up the appliance side
2. Run `terraform apply -parallelism=1` to ensure the Cloudflare side is correct
3. Run `bash output/configure-tunnels.sh --username admin` to push config to the appliances

---

## Reference

### Files You Will Work With

| File | Purpose |
|---|---|
| `terraform.tfvars` | Your Cloudflare credentials and settings — **never commit this** |
| `sites.csv` | Your site list — **never commit this** |
| `output/cpe-config.csv` | Generated by `terraform apply` — all tunnel parameters including PSK |
| `output/configure-tunnels.sh` | Generated by `terraform apply` — configure EdgeConnect appliances (PSK embedded) |
| `output/remove-tunnels.sh` | Generated by `terraform apply` — remove tunnels and VTIs from appliances |

### Files That Contain Secrets

| File | What's in it |
|---|---|
| `terraform.tfvars` | Cloudflare API token |
| `terraform.tfstate` | Pre-shared key in plaintext |
| `output/cpe-config.csv` | Pre-shared key in plaintext |
| `output/configure-tunnels.sh` | Pre-shared key embedded |

All are gitignored. Keep them on your local machine only. Do not share or commit them.

### IP Allocation Logic

Inside addresses are carved from `tunnel_supernet` using `site_index`:

```
site_index = N:
  pri tunnel → /31 subnet #(N × 2)
  sec tunnel → /31 subnet #(N × 2 + 1)

Within each /31:
  lower IP (even) → Cloudflare side
  upper IP (odd)  → EdgeConnect VTI
```

Example with `tunnel_supernet = 10.120.0.0/22` and `site_index = 0`:
```
hq-pri:  10.120.0.0/31   Cloudflare: 10.120.0.0   CPE VTI: 10.120.0.1
hq-sec:  10.120.0.2/31   Cloudflare: 10.120.0.2   CPE VTI: 10.120.0.3
```

**Never change or reuse `site_index` values once a site is deployed** — doing so changes the IP allocation and forces tunnel recreation.
