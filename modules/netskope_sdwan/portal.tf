#------------------------------------------------------------------------------
# Netskope SD-WAN portal objects: policy, gateway(s), interfaces, static routes,
# activation and BGP peers towards Cloud WAN. Ported from the `nsg_config` module;
# BGP neighbors/remote-AS now come from the Cloud WAN Connect peers.
#------------------------------------------------------------------------------

resource "netskopebwan_policy" "multicloud" {
  count = local.portal ? 1 : 0

  name = var.gateway.gateway_policy
}

resource "netskopebwan_gateway" "primary" {
  count = local.portal ? 1 : 0

  name  = var.gateway.gateway_name
  model = var.gateway.gateway_model
  role  = var.gateway.gateway_role
  assigned_policy {
    id   = resource.netskopebwan_policy.multicloud[0].id
    name = resource.netskopebwan_policy.multicloud[0].name
  }
}

# Gateway creation can take a few seconds to create all dependent services in the backend
resource "time_sleep" "primary_gw_propagation" {
  count           = local.portal ? 1 : 0
  create_duration = "30s"

  triggers = {
    gateway_id = netskopebwan_gateway.primary[0].id
  }
}

resource "netskopebwan_gateway" "secondary" {
  count = local.ha && local.portal ? 1 : 0
  name  = "${var.gateway.gateway_name}-ha"
  model = var.gateway.gateway_model
  role  = var.gateway.gateway_role
  assigned_policy {
    id   = resource.netskopebwan_policy.multicloud[0].id
    name = resource.netskopebwan_policy.multicloud[0].name
  }
  depends_on = [netskopebwan_gateway.primary, time_sleep.api_delay]
}

resource "time_sleep" "secondary_gw_propagation" {
  count           = local.ha && local.portal ? 1 : 0
  create_duration = "30s"

  triggers = {
    gateway_id = netskopebwan_gateway.secondary[0].id
  }
}

#### Interfaces ####

resource "netskopebwan_gateway_interface" "primary" {
  for_each = { for intf, subnet in local.primary_gw_enabled_interfaces : intf => subnet if local.portal }

  gateway_id = time_sleep.primary_gw_propagation[0].triggers["gateway_id"]
  name       = upper(each.key)
  type       = "ethernet"
  addresses {
    address            = tolist(aws_network_interface.primary[each.key].private_ips)[0]
    address_assignment = "static"
    address_family     = "ipv4"
    dns_primary        = var.gateway.dns_primary
    dns_secondary      = var.gateway.dns_secondary
    gateway            = cidrhost(each.value.subnet_cidr, 1)
    mask               = cidrnetmask(each.value.subnet_cidr)
  }
  dynamic "overlay_setting" {
    for_each = lookup(merge(local.primary_public_overlay_interfaces, local.primary_private_overlay_interfaces), each.key, null) != null ? [1] : []
    content {
      is_backup           = false
      tx_bw_kbps          = 1000000
      rx_bw_kbps          = 1000000
      bw_measurement_mode = "manual"
      tag                 = lookup(local.primary_public_overlay_interfaces, each.key, null) != null ? "wired" : "private"
    }
  }
  enable_nat  = lookup(local.primary_public_overlay_interfaces, each.key, null) != null
  mode        = "routed"
  is_disabled = false
  zone        = lookup(local.primary_public_overlay_interfaces, each.key, null) != null ? "untrusted" : "trusted"
}

resource "netskopebwan_gateway_interface" "secondary" {
  for_each = { for intf, subnet in local.secondary_gw_enabled_interfaces : intf => subnet if local.portal }

  gateway_id = time_sleep.secondary_gw_propagation[0].triggers["gateway_id"]
  name       = upper(each.key)
  type       = "ethernet"
  addresses {
    address            = tolist(aws_network_interface.secondary[each.key].private_ips)[0]
    address_assignment = "static"
    address_family     = "ipv4"
    dns_primary        = var.gateway.dns_primary
    dns_secondary      = var.gateway.dns_secondary
    gateway            = cidrhost(each.value.subnet_cidr, 1)
    mask               = cidrnetmask(each.value.subnet_cidr)
  }
  dynamic "overlay_setting" {
    for_each = lookup(merge(local.secondary_public_overlay_interfaces, local.secondary_private_overlay_interfaces), each.key, null) != null ? [1] : []
    content {
      is_backup           = false
      tx_bw_kbps          = 1000000
      rx_bw_kbps          = 1000000
      bw_measurement_mode = "manual"
      tag                 = lookup(local.secondary_public_overlay_interfaces, each.key, null) != null ? "wired" : "private"
    }
  }
  enable_nat  = lookup(local.secondary_public_overlay_interfaces, each.key, null) != null
  mode        = "routed"
  is_disabled = false
  zone        = lookup(local.secondary_public_overlay_interfaces, each.key, null) != null ? "untrusted" : "trusted"
}

#### Static routes (EC2 metadata service via the WAN interface) ####

resource "netskopebwan_gateway_staticroute" "metadata_primary" {
  count = local.portal ? 1 : 0

  gateway_id  = time_sleep.primary_gw_propagation[0].triggers["gateway_id"]
  advertise   = true
  destination = "169.254.169.254/32"
  device      = "GE1"
  install     = true
  nhop        = cidrhost(local.primary_gw_enabled_interfaces[sort(keys(local.primary_public_overlay_interfaces))[0]].subnet_cidr, 1)
}

resource "netskopebwan_gateway_staticroute" "metadata_secondary" {
  count = local.ha && local.portal ? 1 : 0

  gateway_id  = time_sleep.secondary_gw_propagation[0].triggers["gateway_id"]
  advertise   = true
  destination = "169.254.169.254/32"
  device      = "GE1"
  install     = true
  nhop        = cidrhost(local.secondary_gw_enabled_interfaces[sort(keys(local.secondary_public_overlay_interfaces))[0]].subnet_cidr, 1)
}

#### Activation ####

resource "netskopebwan_gateway_activate" "primary" {
  count = local.portal ? 1 : 0

  gateway_id         = time_sleep.primary_gw_propagation[0].triggers["gateway_id"]
  timeout_in_seconds = 86400
}

resource "netskopebwan_gateway_activate" "secondary" {
  count = local.ha && local.portal ? 1 : 0

  gateway_id         = time_sleep.secondary_gw_propagation[0].triggers["gateway_id"]
  timeout_in_seconds = 86400
}

#### BGP peers (Cloud WAN Connect peer: two BGP addresses per peer) ####

resource "netskopebwan_gateway_bgpconfig" "cloudwan_primary" {
  count = local.portal ? 2 : 0

  gateway_id = time_sleep.primary_gw_propagation[0].triggers["gateway_id"]
  name       = "cloudwan-peer-${count.index + 1}-primary"
  neighbor   = local.primary_peer.bgp_neighbors[count.index]
  remote_as  = tostring(var.cloudwan.core_network_asn)
}

resource "netskopebwan_gateway_bgpconfig" "cloudwan_secondary" {
  count = local.ha && local.portal ? 2 : 0

  gateway_id = time_sleep.secondary_gw_propagation[0].triggers["gateway_id"]
  name       = "cloudwan-peer-${count.index + 1}-secondary"
  neighbor   = local.secondary_peer.bgp_neighbors[count.index]
  remote_as  = tostring(var.cloudwan.core_network_asn)
}
