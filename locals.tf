locals {
  # -------------------------------------------------------------------
  # 1. Read and decode the input CSV
  # -------------------------------------------------------------------
  sites_raw = csvdecode(file("${path.module}/${var.sites_csv_path}"))

  # Build site list using the explicit site_index from CSV.
  # This ensures IP allocation is stable regardless of CSV row order.
  sites = {
    for site in local.sites_raw : trimspace(site.site_name) => {
      site_index     = tonumber(trimspace(site.site_index))
      site_name      = trimspace(site.site_name)
      customer_gw_ip = trimspace(site.customer_gw_ip)
      lan_subnets    = trimspace(lookup(site, "lan_subnets", ""))
    }
  }

  # -------------------------------------------------------------------
  # 2. Flatten: sites x 2 tunnels -> single map for for_each
  #
  # Key format: "<site_name>-<pri|sec>"
  #   - pri = tunnel to Anycast IP 1 (162.159.66.205)
  #   - sec = tunnel to Anycast IP 2 (172.64.242.205)
  #
  # IP allocation from supernet (10.120.0.0/22):
  #   site_index i ->
  #     pri tunnel: /31 at cidrsubnet(supernet, 9, i * 2)
  #     sec tunnel: /31 at cidrsubnet(supernet, 9, i * 2 + 1)
  #
  # Within each /31:
  #   Cloudflare gets the lower (even) IP: cidrhost(subnet, 0)
  #   Customer gets the upper (odd) IP:    cidrhost(subnet, 1)
  # -------------------------------------------------------------------
  tunnel_definitions = {
    for pair in flatten([
      for name, site in local.sites : [
        {
          key                 = "${site.site_name}-pri"
          site_name           = site.site_name
          tunnel_label        = "pri"
          site_index          = site.site_index
          customer_gw_ip      = site.customer_gw_ip
          lan_subnets         = site.lan_subnets
          cloudflare_endpoint = var.anycast_ip_1
          subnet_index        = site.site_index * 2
        },
        {
          key                 = "${site.site_name}-sec"
          site_name           = site.site_name
          tunnel_label        = "sec"
          site_index          = site.site_index
          customer_gw_ip      = site.customer_gw_ip
          lan_subnets         = site.lan_subnets
          cloudflare_endpoint = var.anycast_ip_2
          subnet_index        = site.site_index * 2 + 1
        },
      ]
    ]) : pair.key => pair
  }

  # -------------------------------------------------------------------
  # 3. Pre-compute IP addresses for each tunnel
  #    newbits=9: /22 + 9 = /31 (512 /31 subnets available)
  # -------------------------------------------------------------------
  tunnel_ips = {
    for key, tun in local.tunnel_definitions : key => {
      interface_cidr = cidrsubnet(var.tunnel_supernet, 9, tun.subnet_index)
      cf_ip          = cidrhost(cidrsubnet(var.tunnel_supernet, 9, tun.subnet_index), 0)
      aruba_ip       = cidrhost(cidrsubnet(var.tunnel_supernet, 9, tun.subnet_index), 1)
    }
  }

  # -------------------------------------------------------------------
  # 4. Route definitions — one entry per (site, subnet, tunnel)
  #    Only created for sites that have lan_subnets populated.
  #    Key format: "<site>-<pri|sec>-<cidr-sanitized>"
  #    e.g. "test-hq-pri-10-1-0-0-24"
  #    Using CIDR in key (not index) so adding/removing a subnet
  #    only affects that route, not others.
  # -------------------------------------------------------------------
  route_definitions = {
    for pair in flatten([
      for name, site in local.sites :
      site.lan_subnets == "" ? [] : flatten([
        for subnet in [for s in split(",", site.lan_subnets) : trimspace(s)] : [
          {
            key          = "${site.site_name}-pri-${replace(replace(subnet, "/", "-"), ".", "-")}"
            site_name    = site.site_name
            tunnel_label = "pri"
            tunnel_key   = "${site.site_name}-pri"
            prefix       = subnet
            priority     = 100
          },
          {
            key          = "${site.site_name}-sec-${replace(replace(subnet, "/", "-"), ".", "-")}"
            site_name    = site.site_name
            tunnel_label = "sec"
            tunnel_key   = "${site.site_name}-sec"
            prefix       = subnet
            priority     = 200
          },
        ]
      ])
    ]) : pair.key => pair
  }
}
