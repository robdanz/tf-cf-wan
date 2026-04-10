# -------------------------------------------------------------------
# Structured output: all tunnel details
# -------------------------------------------------------------------
output "tunnel_details" {
  description = "Map of all tunnel details keyed by tunnel name"
  value = {
    for key, tunnel in cloudflare_magic_wan_ipsec_tunnel.tunnels : key => {
      tunnel_id           = tunnel.id
      tunnel_name         = tunnel.name
      site_name           = local.tunnel_definitions[key].site_name
      tunnel_label        = local.tunnel_definitions[key].tunnel_label
      cloudflare_endpoint = tunnel.cloudflare_endpoint
      customer_endpoint   = tunnel.customer_endpoint
      interface_address   = tunnel.interface_address
      cf_inside_ip        = local.tunnel_ips[key].cf_ip
      cpe_inside_ip       = local.tunnel_ips[key].cpe_ip
      fqdn_id             = "${tunnel.id}.${var.cloudflare_conduit_id}.ipsec.cloudflare.com"
      ec_hostname         = local.tunnel_definitions[key].ec_hostname
    }
  }
}

# -------------------------------------------------------------------
# PSK output (sensitive — use `terraform output -raw tunnel_psk`)
# -------------------------------------------------------------------
output "tunnel_psk" {
  description = "The shared PSK for all tunnels"
  value       = random_password.tunnel_psk.result
  sensitive   = true
}

# -------------------------------------------------------------------
# Per-appliance data for configure-tunnels.sh generation.
# Groups tunnel_definitions by ec_hostname, sorted for deterministic output.
# Each appliance entry carries its site_name and a sorted list of tunnel
# objects with the ECOS JSON payload pre-built (PSK + fqdn_id embedded).
# -------------------------------------------------------------------
locals {
  _appliance_hosts = toset([
    for k, t in local.tunnel_definitions : t.ec_hostname
    if t.ec_hostname != ""
  ])

  appliance_script_data = [
    for ec_host in sort(tolist(local._appliance_hosts)) : {
      ec_host   = ec_host
      site_name = [for k, t in local.tunnel_definitions : t.site_name if t.ec_hostname == ec_host][0]
      tunnels = [
        for k in sort([for k2, t2 in local.tunnel_definitions : k2 if t2.ec_hostname == ec_host]) : {
          tunnel_name   = k
          source        = local.tunnel_definitions[k].customer_gw_ip
          destination   = local.tunnel_definitions[k].cloudflare_endpoint
          cpe_inside_ip = local.tunnel_ips[k].cpe_ip
          prefix_len    = tonumber(split("/", local.tunnel_ips[k].interface_cidr)[1])
          payload = jsonencode({
            (k) = {
              admin            = "up"
              alias            = k
              auto_mtu         = true
              gms_marked       = false
              ipsec_enable     = true
              ipsec_arc_window = "disable"
              presharedkey     = random_password.tunnel_psk.result
              mode             = "ipsec_ip"
              nat_mode         = "none"
              peername         = "Cloudflare_IPSec"
              source           = local.tunnel_definitions[k].customer_gw_ip != "" ? local.tunnel_definitions[k].customer_gw_ip : "0.0.0.0"
              destination      = local.tunnel_definitions[k].cloudflare_endpoint
              max_bw_auto      = true
              local_vrf        = 0
              ipsec = {
                ike_version    = 2
                ike_ealg       = "aes256"
                ike_aalg       = "sha256"
                ike_prf        = "auto"
                dhgroup        = "14"
                pfs            = true
                pfsgroup       = "14"
                ipsec_suite_b  = "none"
                id_type        = "ufqdn"
                ike_id_local   = "${cloudflare_magic_wan_ipsec_tunnel.tunnels[k].id}.${var.cloudflare_conduit_id}.ipsec.cloudflare.com"
                ike_id_remote  = local.tunnel_definitions[k].cloudflare_endpoint
                exchange_mode  = "aggressive"
                mode           = "tunnel"
                esn            = false
                dpd_delay      = 0
                dpd_retry      = 3
                ike_lifetime   = 0
                lifetime       = 240
                lifebytes      = 0
                security = {
                  ah  = { algorithm = "sha256" }
                  esp = { algorithm = "aes256" }
                }
              }
            }
          })
        }
      ]
    }
  ]
}

# -------------------------------------------------------------------
# Generated ECOS configuration script
# Produced by terraform apply — ready to run against EdgeConnect appliances.
# PSK is embedded; output/ is gitignored.
# -------------------------------------------------------------------
resource "local_file" "configure_tunnels_sh" {
  filename        = "${path.module}/output/configure-tunnels.sh"
  file_permission = "0755"

  content = templatefile("${path.module}/aruba/configure-tunnels.tftpl", {
    psk        = random_password.tunnel_psk.result
    appliances = local.appliance_script_data
  })
}

# -------------------------------------------------------------------
# Generated ECOS tunnel removal / rollback script
# Mirrors configure-tunnels.sh but deletes instead of creates.
# Self-contained — works after terraform destroy (no state required).
# -------------------------------------------------------------------
resource "local_file" "remove_tunnels_sh" {
  filename        = "${path.module}/output/remove-tunnels.sh"
  file_permission = "0755"

  content = templatefile("${path.module}/aruba/remove-tunnels.tftpl", {
    appliances = local.appliance_script_data
  })
}

# -------------------------------------------------------------------
# Output CSV for CPE configuration
# -------------------------------------------------------------------
resource "local_file" "cpe_config_csv" {
  filename        = "${path.module}/output/cpe-config.csv"
  file_permission = "0644"

  content = join("\n", concat(
    # Header
    ["site_name,tunnel_label,tunnel_name,tunnel_id,cloudflare_anycast_ip,customer_gw_ip,interface_address_cidr,cf_inside_ip,cpe_inside_ip,fqdn_id,psk"],
    # Data rows sorted by key for deterministic output
    [
      for key in sort(keys(local.tunnel_definitions)) :
      join(",", [
        local.tunnel_definitions[key].site_name,
        local.tunnel_definitions[key].tunnel_label,
        key,
        cloudflare_magic_wan_ipsec_tunnel.tunnels[key].id,
        local.tunnel_definitions[key].cloudflare_endpoint,
        local.tunnel_definitions[key].customer_gw_ip,
        local.tunnel_ips[key].interface_cidr,
        local.tunnel_ips[key].cf_ip,
        local.tunnel_ips[key].cpe_ip,
        "${cloudflare_magic_wan_ipsec_tunnel.tunnels[key].id}.${var.cloudflare_conduit_id}.ipsec.cloudflare.com",
        random_password.tunnel_psk.result,
      ])
    ],
    # Trailing newline
    [""]
  ))
}
