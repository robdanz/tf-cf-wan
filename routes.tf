# -------------------------------------------------------------------
# Static routes — one per (site, subnet, tunnel)
# Nexthop = Cloudflare inside IP of the tunnel (/31 lower address)
# Priority 100 = pri (active), Priority 200 = sec (standby)
# Only created for sites with lan_subnets populated in sites.csv
# -------------------------------------------------------------------
resource "cloudflare_magic_wan_static_route" "routes" {
  for_each = local.route_definitions

  account_id  = var.cloudflare_account_id
  prefix      = each.value.prefix
  nexthop     = local.tunnel_ips[each.value.tunnel_key].cpe_ip
  priority    = each.value.priority
  description = "Site ${each.value.site_name} ${each.value.tunnel_label}"

  depends_on = [cloudflare_magic_wan_ipsec_tunnel.tunnels]
}
