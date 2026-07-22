# -------------------------------------------------------------------
# Single PSK shared across all tunnels
# Using special=false to avoid IKE compatibility issues with some CPE devices
# -------------------------------------------------------------------
resource "random_password" "tunnel_psk" {
  length  = var.psk_length
  special = false
}

# -------------------------------------------------------------------
# IPsec tunnels — one resource instance per tunnel (2 per site)
# -------------------------------------------------------------------
resource "cloudflare_magic_wan_ipsec_tunnel" "tunnels" {
  for_each = local.tunnel_definitions

  account_id          = var.cloudflare_account_id
  name                = each.key
  description         = "Site ${each.value.site_name} ${each.value.tunnel_label} tunnel"
  cloudflare_endpoint = each.value.cloudflare_endpoint
  # Always omitted — even sites with a known customer_gw_ip can sit behind dynamic
  # NAT, so a fixed customer_endpoint would go stale. The tunnel is identified via
  # the FQDN ID (ike_id_local) instead.
  customer_endpoint   = null
  interface_address   = local.tunnel_ips[each.key].interface_cidr
  psk                 = random_password.tunnel_psk.result
  replay_protection          = var.replay_protection
  automatic_return_routing   = true

  health_check = {
    enabled   = var.health_check_enabled
    type      = var.health_check_type
    direction = var.health_check_direction
    rate      = var.health_check_rate
    target    = { saved = local.tunnel_ips[each.key].cpe_ip }
  }
}
