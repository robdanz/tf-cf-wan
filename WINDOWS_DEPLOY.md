# Windows 11 Deployment Guide — From Scratch

This guide walks you through deploying Cloudflare Magic WAN IPsec tunnels and configuring your Aruba EdgeConnect appliances from a Windows 11 PC with no prior tools installed.

**What you will do:**
1. Install the required tools (Git, Terraform) — one-time setup
2. Download this project
3. Configure your Cloudflare credentials
4. Discover your sites from Aruba Orchestrator → `sites.csv`
5. Create the Cloudflare tunnels with Terraform
6. Push the IPsec configuration to your EdgeConnect appliances via PowerShell

**Time required:** 30–60 minutes for first deployment, depending on the number of sites.

---

## Before You Start

Collect the following from your **Cloudflare account team** before beginning. You cannot proceed without these:

| Item                  | Where it comes from                                                             |
| --------------------- | ------------------------------------------------------------------------------- |
| Cloudflare Account ID | Cloudflare dashboard → Account Home → Settings, or visible in the dashboard URL |
| Cloudflare API Token  | You create this (instructions below)                                            |
| Conduit ID            | Provided by your Cloudflare account team                                        |
| Anycast IP 1          | Provided by your Cloudflare account team — primary Magic WAN endpoint           |
| Anycast IP 2          | Provided by your Cloudflare account team — secondary Magic WAN endpoint         |

You will also need:
- Network access to your EdgeConnect appliances (management IPs reachable from your PC)
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
8. **Copy the token immediately** — it is shown only once. Paste it somewhere temporary (Notepad) until you put it in the config file later.

---

## Part 1 — Install Required Tools

All commands in this section are run in **PowerShell**. To open PowerShell: press `Windows + X` and choose **Terminal** or **Windows PowerShell**. A regular (non-Administrator) window is fine for everything in this guide unless noted otherwise.

### 1.1 — Install Git

Git is used to download this project and keep it up to date.

```powershell
winget install --id Git.Git -e --source winget
```

When prompted to accept the license, type `Y` and press Enter. The installer will run in the background.

**After Git installs, close PowerShell and open a new window.** This is required so Windows picks up the updated PATH.

Verify the install:
```powershell
git --version
```
You should see something like `git version 2.47.0.windows.2`. If you see "not recognized," close and reopen PowerShell and try again.

---

### 1.2 — Install Terraform

Terraform is the tool that creates your Cloudflare tunnels.

```powershell
winget install --id Hashicorp.Terraform -e --source winget
```

**After Terraform installs, close PowerShell and open a new window again.**

Verify:
```powershell
terraform version
```
You should see `Terraform v1.x.x`. If you see "not recognized," see the troubleshooting note below.

> **Terraform not found after install?** winget sometimes installs to a path that isn't in your PowerShell PATH yet. If `terraform version` still fails after reopening PowerShell, try:
> ```powershell
> $env:PATH += ";$env:LOCALAPPDATA\Microsoft\WinGet\Packages\Hashicorp.Terraform_Microsoft.Winget.Source_8wekyb3d8bbwe"
> terraform version
> ```
> If that works, add the path permanently: search "Environment Variables" in the Start menu → **Edit the system environment variables** → **Environment Variables** → under **User variables**, select **Path** → **Edit** → **New**, paste the path above.
>
> Alternatively, download Terraform manually: go to [https://developer.hashicorp.com/terraform/install](https://developer.hashicorp.com/terraform/install), download the **Windows AMD64** zip, extract it, and place `terraform.exe` in `C:\Windows\System32` (requires Administrator PowerShell: right-click Terminal → Run as Administrator).

---

### 1.3 — Allow PowerShell Scripts to Run

By default, Windows blocks locally-created PowerShell scripts. Run this once to allow them:

```powershell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
```

Type `Y` and press Enter when prompted. This only affects your user account, not the whole system.

---

## Part 2 — Download the Project

### 2.1 — Clone the Repository

Choose a location for the project files. Your Documents folder is a good choice.

```powershell
cd $HOME\Documents
git clone https://github.com/robdanz/tf-cf-wan.git
cd tf-cf-wan
```

This creates a `tf-cf-wan` folder and downloads all project files into it.

> **No internet access to GitHub from your PC?** Download the ZIP instead: go to the GitHub repository page, click the green **Code** button → **Download ZIP**. Extract the ZIP to `C:\Users\YourName\Documents\tf-cf-wan`. Then open PowerShell and `cd` to that folder.

---

### 2.2 — Open the Project Folder in File Explorer

It's useful to have File Explorer open alongside PowerShell. Run:

```powershell
explorer .
```

This opens File Explorer at the project root. You will use this to edit files.

---

## Part 3 — Configure Your Credentials

### 3.1 — Create terraform.tfvars

`terraform.tfvars` is the configuration file that holds your Cloudflare credentials and settings. It is excluded from version control (gitignored) and must never be committed or shared — it contains your API token.

Copy the example file to create your own:

```powershell
Copy-Item terraform.tfvars.example terraform.tfvars
```

### 3.2 — Edit terraform.tfvars

Open `terraform.tfvars` in Notepad (or any text editor — VS Code, Notepad++):

```powershell
notepad terraform.tfvars
```

Fill in your values. Replace every placeholder in quotes with your actual values:

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
# conflict with your existing networks. The default below is a safe starting point.
tunnel_supernet = "10.120.0.0/22"
```

The remaining lines in the file (health check settings, replay protection) can be left at their defaults for now.

Save and close.

> **Important:** The `tunnel_supernet` range is used for tunnel inside addresses (VTI IPs) — not for your LAN subnets. It should be a /22 or larger private range that is not in use anywhere in your network.

---

## Part 4 — Discover Sites and Prepare sites.csv

`sites.csv` tells Terraform which sites to build tunnels for. Each row = one site = two Cloudflare tunnels (primary + secondary).

### Option A — Generate from Aruba Orchestrator (recommended)

If you have an Aruba Orchestrator, the PowerShell script `aruba\Get-SiteDetails.ps1` queries it automatically and builds the CSV for you. This is the recommended path — it discovers all appliances, their WAN IPs, and picks the right management IP to use for each appliance type.

#### 4A.1 — Get your Orchestrator API token

The script authenticates with an Orchestrator API token (not username/password). A **Site Admin, read-only** role is sufficient — the script only reads data.

Obtain a token from your Orchestrator administrator, or create one:
1. Log into the Orchestrator web UI
2. Navigate to **Administration** → **API Tokens** (exact path varies by firmware version)
3. Create a new token with read-only access
4. Copy the token value

#### 4A.2 — Set your token as an environment variable

Setting it as an environment variable means you don't have to type it repeatedly:

```powershell
$env:ARUBA_API_TOKEN = "paste-your-token-here"
```

> This only lasts for the current PowerShell session. To make it permanent across sessions, search "Environment Variables" in the Start menu → **Edit the system environment variables** → **Environment Variables** → under **User variables**, click **New**, set name `ARUBA_API_TOKEN` and value to your token.

#### 4A.3 — Run the discovery script

From the repo root, replacing `10.0.0.100` with your Orchestrator's IP or hostname:

```powershell
.\aruba\Get-SiteDetails.ps1 -Orchestrator 10.0.0.100
```

Or, if you prefer to pass the token directly instead of using the environment variable:

```powershell
.\aruba\Get-SiteDetails.ps1 -Orchestrator 10.0.0.100 -Token "your-token-here"
```

The script connects to the Orchestrator, queries every appliance for interface state and subnet data, prints a summary to the screen, and writes `sites.csv.proposed` to the repo root.

**Example output:**

```
INFO  Fetching appliance list from 10.0.0.100...
INFO  Found 3 appliance(s)...
INFO    Processing HQ-EC (NePk001)...
INFO    Processing Chicago-EC (NePk002)...
INFO    Processing Denver-EC (NePk003)...

============================================================
 SITE DETAILS SUMMARY
============================================================
Site: HQ-EC (NePk001)  api_target=10.1.0.10  [mgmt0]
  customer_gw_ip:      203.0.113.10
  WAN interfaces:
    wan0: 203.0.113.10/30
  LAN interfaces:
    lan0: 10.10.0.1/24
  Advertised/local LAN subnets:
    10.10.0.0/24

...
============================================================

INFO  Written to: C:\Users\YourName\Documents\tf-cf-wan\sites.csv.proposed
```

#### 4A.4 — Review sites.csv.proposed

Open the proposed file to review it before accepting:

```powershell
notepad sites.csv.proposed
```

Check each row:
- **`site_name`** — auto-generated from the appliance hostname. Edit if it's unclear or too long.
- **`customer_gw_ip`** — the appliance's public WAN IP. If blank, the site is treated as NAT'd/dynamic. Verify this is intentional. If an appliance has multiple WAN interfaces, the script picks the first one with a public IP — edit if the wrong IP was chosen.
- **`ec_hostname`** — the management IP the configure script will connect to. The script sets this to `mgmt0` IP for virtual appliances and the Orchestrator management IP for hardware appliances. Replace with a DNS name if you prefer.
- **`site_index`** — auto-assigned in alphabetical order starting from 0. **Do not change or reuse these once a site has been deployed** — they control IP allocation and changing them forces tunnel recreation.

#### 4A.5 — Accept the proposed CSV

Once you're satisfied with the contents:

```powershell
Copy-Item sites.csv.proposed sites.csv
```

Proceed to Part 5.

---

### Option B — Create sites.csv Manually

If you don't have an Orchestrator, create `sites.csv` by hand.

In File Explorer, right-click in the project folder → **New** → **Text Document**. Name it `sites.csv`. Make sure Windows doesn't add `.txt` — if it does, rename it and delete the `.txt` extension. (To see file extensions in File Explorer: **View** → **Show** → **File name extensions**.)

Open it in Notepad and enter your sites:

```csv
site_name,site_index,customer_gw_ip,ec_hostname
hq,0,203.0.113.10,10.0.0.1
chicago,1,198.51.100.20,10.0.0.2
denver,2,,10.0.0.3
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

**NAT'd or dynamic sites (`customer_gw_ip` left blank):** The configure script uses `ec_hostname` as the IPsec tunnel source IP. NAT traversal (NAT-T) handles the public mapping automatically.

> **Tip:** Use Notepad or another plain text editor, not Excel. Excel may silently reformat the file in ways that break Terraform's CSV parser. If you must use Excel, save as **CSV UTF-8 (Comma delimited)** and verify the output in Notepad afterward.

---

## Part 5 — Deploy Cloudflare Tunnels with Terraform

All commands below are run in PowerShell from the project root (`tf-cf-wan` folder).

Verify you are in the right directory:
```powershell
pwd
# Should show: C:\Users\YourName\Documents\tf-cf-wan
```

### 5.1 — Initialize Terraform

This downloads the Cloudflare provider plugin. Only needed once per machine (or after deleting the `.terraform` folder).

```powershell
terraform init
```

You should see output ending with:
```
Terraform has been successfully initialized!
```

If you see errors about the provider not being found, check your internet connection and re-run.

---

### 5.2 — Preview What Will Be Created

```powershell
terraform plan
```

This does not make any changes — it shows you exactly what Terraform would create. Review the output. You should see one `cloudflare_magic_wan_ipsec_tunnel` resource per site label (two per site: `hq-pri`, `hq-sec`, etc.) and corresponding static routes.

If you see errors here, they usually mean:
- A value in `terraform.tfvars` is missing or wrong
- `sites.csv` has a formatting issue (check for extra spaces, wrong column names)
- The Cloudflare API token doesn't have the right permissions

---

### 5.3 — Deploy

```powershell
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

Terraform will now create the tunnels. With many sites this may take several minutes — it creates resources sequentially due to `-parallelism=1`. You'll see each resource created as it goes.

When complete, you'll see:
```
Apply complete! Resources: X added, 0 changed, 0 destroyed.
```

This also writes four files to the `output\` folder:
- `output\cpe-config.csv` — all tunnel parameters in one place (IPs, IDs, PSK)
- `output\configure-tunnels.ps1` — PowerShell script to configure EdgeConnect appliances (PSK embedded)
- `output\remove-tunnels.ps1` — PowerShell script to remove tunnels and VTIs from appliances
- `output\configure-tunnels.sh` — Bash version of the configure script (for Mac/Linux use)

---

### 5.4 — Retrieve the Pre-Shared Key

The PSK was randomly generated and is embedded in the tunnel config. Retrieve it:

```powershell
terraform output -raw tunnel_psk
```

Save this value somewhere secure — you may need it for manual CPE configuration or troubleshooting. It is also visible in `output\cpe-config.csv`.

---

### 5.5 — Review Tunnel Details

All tunnel parameters (IPs, tunnel IDs, FQDN identifiers) are in `output\cpe-config.csv`. Open it in Notepad or Excel to review.

To see the raw Terraform output:
```powershell
terraform output -json tunnel_details
```

---

## Part 6 — Configure EdgeConnect Appliances

The PowerShell script `output\configure-tunnels.ps1` is generated by `terraform apply` and pushes the IPsec tunnel configuration and VTIs to each EdgeConnect appliance via the ECOS REST API. The PSK and all tunnel parameters are embedded — no Terraform dependency at run time.

**Prerequisites before running:**
- `terraform apply` must have completed successfully (this generates `output\configure-tunnels.ps1`)
- Your PC must be able to reach each appliance's management IP (the `ec_hostname` values from `sites.csv`)
- You need the EdgeConnect admin credentials

### 6.1 — Dry Run First (Recommended)

Always preview before making changes:

```powershell
.\output\configure-tunnels.ps1 -DryRun
```

This prints what it would do — which appliances it would connect to, which tunnels it would create — without making any API calls. Verify the site list and tunnel names look correct.

---

### 6.2 — Run the Configuration

**Static sites** (all sites have a `customer_gw_ip`):

```powershell
.\output\configure-tunnels.ps1
```

**NAT'd or dynamic sites** (any site has a blank `customer_gw_ip`): The script needs to resolve the appliance's current WAN IP from the Orchestrator at run time. Make sure `$env:ARUBA_API_TOKEN` is set (from Step 4A.2), then:

```powershell
.\output\configure-tunnels.ps1 -Orchestrator 10.0.0.100
```

Or pass the token directly:

```powershell
.\output\configure-tunnels.ps1 -Orchestrator 10.0.0.100 -OrchToken "your-token-here"
```

You will be prompted once for the EdgeConnect admin password. The same password is used for all appliances.

```
EdgeConnect password for admin: ●●●●●●●●
```

The script will log into each appliance, create both IPsec tunnels (`site-pri` and `site-sec`), and create the corresponding VTIs. Progress is printed as it runs:

```
INFO  Sites to configure: hq, chicago, denver

INFO  Site: hq  appliance: 10.0.0.1  tunnels: 2
  Logging in to 10.0.0.1... OK
  Creating hq-pri... OK
INFO      VTI OK (vti110)
  Creating hq-sec... OK
INFO      VTI OK (vti111)

INFO  Site: chicago  appliance: 10.0.0.2  tunnels: 2
  ...
```

The script is **idempotent** — if a tunnel already exists on the appliance, it skips creation and moves on. Safe to re-run.

---

### 6.3 — Common Options

**Different username:**
```powershell
.\output\configure-tunnels.ps1 -Username ecdeploy
```

**Specific appliances only** (useful for testing or partial deployment):
```powershell
.\output\configure-tunnels.ps1 -Sites "10.0.0.1,10.0.0.2"
```

Note: `-Sites` filters by **appliance IP/hostname** (the `ec_hostname` values), not by site name.

**If your appliances have valid TLS certificates** (uncommon — most use self-signed):
```powershell
.\output\configure-tunnels.ps1 -VerifySSL
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

```powershell
# Preview first:
.\output\remove-tunnels.ps1 -DryRun

# Execute:
.\output\remove-tunnels.ps1
```

The remove script is generated by `terraform apply` with all tunnel names embedded — it does not require Terraform or the state file at run time. It will:
1. Log into each appliance
2. Find and delete the passthrough tunnels by name
3. Find and delete the VTIs associated with those tunnels

**Specific appliances only:**
```powershell
.\output\remove-tunnels.ps1 -Sites "10.0.0.1,10.0.0.2"
```

---

### 7.2 — Destroy Cloudflare Resources

After (or instead of) removing the appliance config:

```powershell
terraform destroy -parallelism=1
```

Type `yes` when prompted. This deletes all Cloudflare tunnels and static routes created by this project.

---

## Part 8 — Day 2 Operations

### Adding New Sites

1. Add new rows to `sites.csv`. Use the next available `site_index` (never reuse or change existing ones).
2. Run `terraform apply -parallelism=1` — only new resources will be created, and the `output\` scripts are regenerated.
3. Run `.\output\configure-tunnels.ps1 -Sites "new-appliance-ip"` to configure only the new appliances.

### Removing Sites

1. Delete the site's row from `sites.csv`.
2. Run `.\output\remove-tunnels.ps1 -Sites "appliance-ip"` to clean up the appliance first.
3. Run `terraform apply -parallelism=1` — Terraform will destroy the tunnels for that site.

### Updating After a Terraform Change

If you change `terraform.tfvars` settings (health check direction, replay protection, etc.):
1. Run `terraform apply -parallelism=1`
2. No action needed on the appliances for most Cloudflare-side changes.

### Getting the Current PSK

```powershell
terraform output -raw tunnel_psk
```

---

## Troubleshooting

### Get-SiteDetails.ps1 returns "Could not reach Orchestrator"
- Verify the Orchestrator IP/hostname: `Test-NetConnection 10.0.0.100 -Port 443`
- Verify your API token is correct — a wrong token returns `401 Unauthorized`
- Verify the token has at least **Site Admin, read-only** access
- If the Orchestrator uses a self-signed certificate, do not use `-VerifySSL` (the default skips cert verification)

### Get-SiteDetails.ps1 shows all sites with blank customer_gw_ip
All appliances are behind NAT or have dynamic WAN IPs. Check the WAN interfaces section of the summary — if no public IPs appear, the Orchestrator may not have current interface state. Try running without `&cached=true` by contacting your Orchestrator admin, or fill in `customer_gw_ip` manually in `sites.csv`.

### "terraform is not recognized"
Close PowerShell completely and open a new window. If it still fails, see the Terraform installation note in Step 1.2.

### "Running scripts is disabled on this system"
Run this once in PowerShell:
```powershell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
```
Then close and reopen PowerShell.

### `terraform apply` returns 429 errors
You forgot `-parallelism=1`. The Cloudflare Magic WAN API only allows one write at a time. Always use:
```powershell
terraform apply -parallelism=1
```

### `terraform apply` returns 400 errors (code 1012)
This is a transient Cloudflare infrastructure glitch. Just re-run:
```powershell
terraform apply -parallelism=1
```
Terraform picks up where it left off and only retries the failed resources.

### "Duplicate /31 address" error during apply
This happens when you replace all sites with a completely new `sites.csv` (new `site_index` values). Terraform tries to create new tunnels before destroying old ones, and Cloudflare rejects duplicates. Fix: destroy first, then apply.
```powershell
terraform destroy -parallelism=1
terraform apply -parallelism=1
```

### PowerShell script returns "Could not read terraform outputs"
The script must be run from the repo root folder (`tf-cf-wan`), not from inside `aruba\`. Also ensure `terraform apply` has been run and completed successfully.

### Login to appliance returns "You are not authenticated"
- Verify the management IP in `ec_hostname` is reachable: `Test-NetConnection 10.0.0.1 -Port 443`
- Verify the username and password are correct
- Verify HTTPS (port 443) is accessible on the appliance — some appliances use a non-standard port

### Tunnel exists on appliance but not on Cloudflare (or vice versa)
The `configure-tunnels.ps1` script is idempotent on the appliance side (skips existing tunnels). If a tunnel is stuck in a partial state:
1. Run `output\remove-tunnels.ps1` to clean up the appliance side
2. Run `terraform apply -parallelism=1` to ensure the Cloudflare side is correct
3. Run `output\configure-tunnels.ps1` to push config to the appliances

### Sites with blank `customer_gw_ip` (NAT'd sites)
Pass `-Orchestrator` to `output\configure-tunnels.ps1` so it can resolve each appliance's WAN IP at run time. Set `$env:ARUBA_API_TOKEN` so you don't have to pass `-OrchToken` each time.

---

## Reference

### Files You Will Work With

| File | Purpose |
|---|---|
| `terraform.tfvars` | Your Cloudflare credentials and settings — **never commit this** |
| `sites.csv` | Your site list — **never commit this** |
| `output\cpe-config.csv` | Generated by `terraform apply` — all tunnel parameters including PSK |
| `output\configure-tunnels.ps1` | Generated by `terraform apply` — configure EdgeConnect appliances (PSK embedded) |
| `output\remove-tunnels.ps1` | Generated by `terraform apply` — remove tunnels and VTIs from appliances |

### Files That Contain Secrets

| File | What's in it |
|---|---|
| `terraform.tfvars` | Cloudflare API token |
| `terraform.tfstate` | Pre-shared key in plaintext |
| `output\cpe-config.csv` | Pre-shared key in plaintext |
| `output\configure-tunnels.ps1` | Pre-shared key embedded |

All are gitignored. Keep them on your local machine only. Do not email, share, or commit them.

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

**Never change or reuse `site_index` values once a site is deployed** — doing so changes the IP allocation for that site and forces tunnel recreation.
