#------------------------------------------------------------------------------
# Cloud WAN connectivity of the SD-WAN VPC. Replaces the Transit Gateway part of
# the original module (aws_ec2_transit_gateway*, TGW Connect + Connect peers):
#
#   VPC attachment (transport, LAN subnets)  ->  Connect attachment (GRE)  ->  Connect peer(s) (BGP)
#
# Both attachments carry the segment tag matched by the attachment policy.
#------------------------------------------------------------------------------

locals {
  attachment_tags = merge(var.tags, { (var.cloudwan.segment_tag_key) = var.cloudwan.segment })

  attach_subnet_arns = concat(
    [aws_subnet.primary[local.primary_lan_interface].arn],
    local.ha ? [aws_subnet.secondary[local.secondary_lan_interface].arn] : []
  )
}

resource "aws_networkmanager_vpc_attachment" "transport" {
  core_network_id = var.cloudwan.core_network_id
  vpc_arn         = aws_vpc.this.arn
  subnet_arns     = local.attach_subnet_arns

  tags = merge(local.attachment_tags, { Name = "${local.name}-transport" })
}

# GRE endpoints of Cloud WAN (inside CIDR of the core network) are reached through the core network.
resource "aws_route" "to_core_network_inside_cidr" {
  for_each = toset(var.cloudwan.inside_cidr_blocks)

  route_table_id         = aws_route_table.private.id
  destination_cidr_block = each.value
  core_network_arn       = var.cloudwan.core_network_arn

  depends_on = [aws_networkmanager_vpc_attachment.transport]
}

resource "aws_networkmanager_connect_attachment" "this" {
  core_network_id         = var.cloudwan.core_network_id
  transport_attachment_id = aws_networkmanager_vpc_attachment.transport.id
  edge_location           = aws_networkmanager_vpc_attachment.transport.edge_location

  options {
    protocol = "GRE"
  }

  tags = merge(local.attachment_tags, { Name = "${local.name}-connect" })
}

resource "time_sleep" "api_delay" {
  create_duration = "30s"

  triggers = {
    connect_attachment_id = aws_networkmanager_connect_attachment.this.id
  }
}

resource "aws_networkmanager_connect_peer" "primary" {
  connect_attachment_id = time_sleep.api_delay.triggers["connect_attachment_id"]
  peer_address          = tolist(aws_network_interface.primary[local.primary_lan_interface].private_ips)[0]
  inside_cidr_blocks    = [var.cloudwan.primary_inside_cidr]

  bgp_options {
    peer_asn = tonumber(var.tenant.tenant_bgp_asn)
  }

  tags = merge(var.tags, { Name = "${local.name}-bgp-primary" })
}

resource "aws_networkmanager_connect_peer" "secondary" {
  count = local.ha ? 1 : 0

  connect_attachment_id = time_sleep.api_delay.triggers["connect_attachment_id"]
  peer_address          = tolist(aws_network_interface.secondary[local.secondary_lan_interface].private_ips)[0]
  inside_cidr_blocks    = [var.cloudwan.secondary_inside_cidr]

  bgp_options {
    peer_asn = tonumber(var.tenant.tenant_bgp_asn)
  }

  tags = merge(var.tags, { Name = "${local.name}-bgp-secondary" })
}

locals {
  # Values reported by Cloud WAN for each Connect peer. The fallbacks follow the documented convention
  # (1st address of the inside CIDR = gateway, 2nd and 3rd = Cloud WAN BGP addresses).
  primary_peer_cfg   = aws_networkmanager_connect_peer.primary.configuration[0]
  secondary_peer_cfg = local.ha ? aws_networkmanager_connect_peer.secondary[0].configuration[0] : null

  primary_peer = {
    gre_remote_ip = local.primary_peer_cfg.core_network_address
    inside_ip     = try(local.primary_peer_cfg.bgp_configurations[0].peer_address, cidrhost(var.cloudwan.primary_inside_cidr, 1))
    bgp_neighbors = [
      try(local.primary_peer_cfg.bgp_configurations[0].core_network_address, cidrhost(var.cloudwan.primary_inside_cidr, 2)),
      try(local.primary_peer_cfg.bgp_configurations[1].core_network_address, cidrhost(var.cloudwan.primary_inside_cidr, 3)),
    ]
  }

  secondary_peer = local.ha ? {
    gre_remote_ip = local.secondary_peer_cfg.core_network_address
    inside_ip     = try(local.secondary_peer_cfg.bgp_configurations[0].peer_address, cidrhost(var.cloudwan.secondary_inside_cidr, 1))
    bgp_neighbors = [
      try(local.secondary_peer_cfg.bgp_configurations[0].core_network_address, cidrhost(var.cloudwan.secondary_inside_cidr, 2)),
      try(local.secondary_peer_cfg.bgp_configurations[1].core_network_address, cidrhost(var.cloudwan.secondary_inside_cidr, 3)),
    ]
  } : null
}
