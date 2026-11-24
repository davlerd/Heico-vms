#------------------------------------------------------------------------------
# Gateway instance (Netskope SD-WAN / Unified SASE Gateway AMI from AWS Marketplace).
# Ported from the `aws_ec2` module and aligned with the greenfield template downloaded
# from the Netskope console (explicit AMI ID, c5.xlarge, gp3 root volume, cloud-init password).
#------------------------------------------------------------------------------

data "aws_ami" "netskope_gw" {
  count = var.instance.ami_id == null ? 1 : 0

  most_recent = true
  owners      = [var.instance.ami_owner]

  filter {
    name   = "name"
    values = ["${var.instance.ami_name}*"]
  }
}

locals {
  ami_id = coalesce(var.instance.ami_id, try(data.aws_ami.netskope_gw[0].image_id, null))

  # Console flow: only a cloud-init password (console / optional SSH password login).
  console_user_data = var.gateway_password == "" ? null : templatefile("${path.module}/scripts/user-data-console.sh", {
    password          = var.gateway_password
    ssh_password_auth = var.ssh_password_auth
  })
}

resource "aws_instance" "primary" {
  ami           = local.ami_id
  instance_type = var.instance.instance_type
  key_name      = var.ssh_key_name

  user_data = local.portal ? templatefile("${path.module}/scripts/user-data.sh", {
    netskope_gw_default_password = var.gateway_password
    netskope_tenant_url          = var.tenant.tenant_url
    netskope_gw_activation_key   = netskopebwan_gateway_activate.primary[0].token
    netskope_gw_bgp_metric       = "10"
    netskope_gw_asn              = var.tenant.tenant_bgp_asn
    transit_gw_peer_inside_ip1   = local.primary_peer.bgp_neighbors[0]
    transit_gw_peer_inside_ip2   = local.primary_peer.bgp_neighbors[1]
  }) : local.console_user_data

  root_block_device {
    volume_size = var.instance.root_volume_size
    volume_type = var.instance.root_volume_type
    encrypted   = true
  }

  dynamic "network_interface" {
    for_each = { for i, k in sort(keys(aws_network_interface.primary)) : k => i }
    content {
      network_interface_id = aws_network_interface.primary[network_interface.key].id
      device_index         = network_interface.value
    }
  }

  tags = merge(var.tags, { Name = "${local.name}-primary" })
}

resource "aws_instance" "secondary" {
  count = local.ha ? 1 : 0

  ami           = local.ami_id
  instance_type = var.instance.instance_type
  key_name      = var.ssh_key_name

  user_data = local.portal ? templatefile("${path.module}/scripts/user-data.sh", {
    netskope_gw_default_password = var.gateway_password
    netskope_tenant_url          = var.tenant.tenant_url
    netskope_gw_activation_key   = netskopebwan_gateway_activate.secondary[0].token
    netskope_gw_bgp_metric       = "20"
    netskope_gw_asn              = var.tenant.tenant_bgp_asn
    transit_gw_peer_inside_ip1   = local.secondary_peer.bgp_neighbors[0]
    transit_gw_peer_inside_ip2   = local.secondary_peer.bgp_neighbors[1]
  }) : local.console_user_data

  root_block_device {
    volume_size = var.instance.root_volume_size
    volume_type = var.instance.root_volume_type
    encrypted   = true
  }

  dynamic "network_interface" {
    for_each = { for i, k in sort(keys(aws_network_interface.secondary)) : k => i }
    content {
      network_interface_id = aws_network_interface.secondary[network_interface.key].id
      device_index         = network_interface.value
    }
  }

  tags = merge(var.tags, { Name = "${local.name}-secondary" })
}
