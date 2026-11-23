#------------------------------------------------------------------------------
# Netskope SD-WAN gateway VPC: VPC, IGW, subnets, route tables, security groups,
# ENIs and EIPs. Ported from the Netskope `aws_vpc` module (create-VPC mode).
#------------------------------------------------------------------------------

data "aws_availability_zones" "this" {
  state = "available"
}

locals {
  name = "${var.name_prefix}${var.vpc.name}"
  ha   = var.gateway.ha_enabled

  # Portal objects are managed by Terraform only in the legacy API flow
  portal = var.portal_automation

  primary_zone   = coalesce(var.vpc.primary_zone, data.aws_availability_zones.this.names[0])
  secondary_zone = coalesce(var.vpc.secondary_zone, try(data.aws_availability_zones.this.names[1], data.aws_availability_zones.this.names[0]))

  # Interfaces enabled per gateway (the secondary gateway only exists with HA).
  primary_gw_enabled_interfaces = {
    for intf, subnet in var.vpc.primary_gw_subnets : intf => subnet if subnet != null
  }
  secondary_gw_enabled_interfaces = {
    for intf, subnet in(local.ha ? var.vpc.secondary_gw_subnets : var.vpc.primary_gw_subnets) : intf => subnet if subnet != null && local.ha
  }

  primary_public_overlay_interfaces = {
    for intf, subnet in local.primary_gw_enabled_interfaces : intf => subnet if subnet.overlay == "public"
  }
  primary_private_overlay_interfaces = {
    for intf, subnet in local.primary_gw_enabled_interfaces : intf => subnet if subnet.overlay == "private"
  }
  secondary_public_overlay_interfaces = {
    for intf, subnet in local.secondary_gw_enabled_interfaces : intf => subnet if subnet.overlay == "public"
  }
  secondary_private_overlay_interfaces = {
    for intf, subnet in local.secondary_gw_enabled_interfaces : intf => subnet if subnet.overlay == "private"
  }

  # LAN interfaces = interfaces without overlay; if there are none, the private-overlay ones.
  primary_non_overlay_interfaces   = setsubtract(keys(local.primary_gw_enabled_interfaces), keys(merge(local.primary_public_overlay_interfaces, local.primary_private_overlay_interfaces)))
  primary_lan_interfaces           = length(local.primary_non_overlay_interfaces) != 0 ? sort(tolist(local.primary_non_overlay_interfaces)) : sort(keys(local.primary_private_overlay_interfaces))
  secondary_non_overlay_interfaces = setsubtract(keys(local.secondary_gw_enabled_interfaces), keys(merge(local.secondary_public_overlay_interfaces, local.secondary_private_overlay_interfaces)))
  secondary_lan_interfaces         = length(local.secondary_non_overlay_interfaces) != 0 ? sort(tolist(local.secondary_non_overlay_interfaces)) : sort(keys(local.secondary_private_overlay_interfaces))

  primary_lan_interface   = local.primary_lan_interfaces[0]
  secondary_lan_interface = local.ha ? local.secondary_lan_interfaces[0] : null
}

#### VPC ####

resource "aws_vpc" "this" {
  cidr_block           = var.vpc.cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = merge(var.tags, { Name = local.name })
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = merge(var.tags, { Name = "${local.name}-igw" })
}

#### Subnets ####

resource "aws_subnet" "primary" {
  for_each = local.primary_gw_enabled_interfaces

  vpc_id            = aws_vpc.this.id
  cidr_block        = each.value.subnet_cidr
  availability_zone = local.primary_zone
  tags              = merge(var.tags, { Name = "${local.name}-primary-${each.key}" })
}

resource "aws_subnet" "secondary" {
  for_each = local.secondary_gw_enabled_interfaces

  vpc_id            = aws_vpc.this.id
  cidr_block        = each.value.subnet_cidr
  availability_zone = local.secondary_zone
  tags              = merge(var.tags, { Name = "${local.name}-secondary-${each.key}" })
}

#### Route tables ####

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  tags   = merge(var.tags, { Name = "${local.name}-public" })
}

resource "aws_route" "public_default" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id
  tags   = merge(var.tags, { Name = "${local.name}-private" })
}

resource "aws_route_table_association" "primary_public" {
  for_each       = local.primary_public_overlay_interfaces
  subnet_id      = aws_subnet.primary[each.key].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "primary_lan" {
  for_each       = toset(local.primary_lan_interfaces)
  subnet_id      = aws_subnet.primary[each.key].id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "secondary_public" {
  for_each       = local.secondary_public_overlay_interfaces
  subnet_id      = aws_subnet.secondary[each.key].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "secondary_lan" {
  for_each       = local.ha ? toset(local.secondary_lan_interfaces) : toset([])
  subnet_id      = aws_subnet.secondary[each.key].id
  route_table_id = aws_route_table.private.id
}

#### Security groups ####

resource "aws_security_group" "public" {
  name        = "${local.name}-public"
  description = "Netskope SD-WAN gateway - WAN (public overlay) interfaces"
  vpc_id      = aws_vpc.this.id
  tags        = merge(var.tags, { Name = "${local.name}-public" })
}

resource "aws_vpc_security_group_ingress_rule" "public_overlay" {
  security_group_id = aws_security_group.public.id
  description       = "Netskope SD-WAN overlay (IPsec NAT-T)"
  ip_protocol       = "udp"
  from_port         = 4500
  to_port           = 4500
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_ingress_rule" "public_ssh" {
  for_each = toset(var.ssh_allowed_cidrs)

  security_group_id = aws_security_group.public.id
  description       = "SSH"
  ip_protocol       = "tcp"
  from_port         = 22
  to_port           = 22
  cidr_ipv4         = each.value
}

resource "aws_vpc_security_group_ingress_rule" "public_https" {
  for_each = toset(var.https_allowed_cidrs)

  security_group_id = aws_security_group.public.id
  description       = "HTTPS"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = each.value
}

resource "aws_vpc_security_group_egress_rule" "public_all" {
  security_group_id = aws_security_group.public.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_security_group" "private" {
  name        = "${local.name}-private"
  description = "Netskope SD-WAN gateway - LAN interfaces"
  vpc_id      = aws_vpc.this.id
  tags        = merge(var.tags, { Name = "${local.name}-private" })
}

resource "aws_vpc_security_group_ingress_rule" "private" {
  for_each = toset(concat([var.vpc.cidr], var.private_cidrs, var.cloudwan.inside_cidr_blocks))

  security_group_id = aws_security_group.private.id
  description       = "Private ranges and Cloud WAN GRE endpoints"
  ip_protocol       = "-1"
  cidr_ipv4         = each.value
}

resource "aws_vpc_security_group_egress_rule" "private_all" {
  security_group_id = aws_security_group.private.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

#### Network interfaces and EIPs ####
# source/dest check is disabled on every interface: the gateway routes and NATs traffic.

resource "aws_network_interface" "primary" {
  for_each = local.primary_gw_enabled_interfaces

  subnet_id         = aws_subnet.primary[each.key].id
  private_ips       = each.value.private_ip != null ? [each.value.private_ip] : null
  security_groups   = contains(keys(local.primary_public_overlay_interfaces), each.key) ? [aws_security_group.public.id] : [aws_security_group.private.id]
  source_dest_check = false
  tags              = merge(var.tags, { Name = "${local.name}-primary-${each.key}" })
}

resource "aws_network_interface" "secondary" {
  for_each = local.secondary_gw_enabled_interfaces

  subnet_id         = aws_subnet.secondary[each.key].id
  private_ips       = each.value.private_ip != null ? [each.value.private_ip] : null
  security_groups   = contains(keys(local.secondary_public_overlay_interfaces), each.key) ? [aws_security_group.public.id] : [aws_security_group.private.id]
  source_dest_check = false
  tags              = merge(var.tags, { Name = "${local.name}-secondary-${each.key}" })
}

resource "aws_eip" "primary" {
  for_each = local.primary_public_overlay_interfaces

  domain                    = "vpc"
  network_interface         = aws_network_interface.primary[each.key].id
  associate_with_private_ip = tolist(aws_network_interface.primary[each.key].private_ips)[0]
  tags                      = merge(var.tags, { Name = "${local.name}-primary-${each.key}" })

  depends_on = [aws_internet_gateway.this]
}

resource "aws_eip" "secondary" {
  for_each = local.secondary_public_overlay_interfaces

  domain                    = "vpc"
  network_interface         = aws_network_interface.secondary[each.key].id
  associate_with_private_ip = tolist(aws_network_interface.secondary[each.key].private_ips)[0]
  tags                      = merge(var.tags, { Name = "${local.name}-secondary-${each.key}" })

  depends_on = [aws_internet_gateway.this]
}
