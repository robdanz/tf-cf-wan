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
