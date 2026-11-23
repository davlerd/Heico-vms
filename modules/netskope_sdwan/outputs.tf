output "vpc_id" {
  description = "ID of the SD-WAN VPC."
  value       = aws_vpc.this.id
}

output "vpc_cidr" {
  description = "CIDR of the SD-WAN VPC."
  value       = aws_vpc.this.cidr_block
}

output "transport_attachment_id" {
  description = "Cloud WAN VPC (transport) attachment ID."
  value       = aws_networkmanager_vpc_attachment.transport.id
}

output "connect_attachment_id" {
  description = "Cloud WAN Connect attachment ID."
  value       = aws_networkmanager_connect_attachment.this.id
}

output "gateway_public_ips" {
  description = "EIPs of the WAN interfaces."
  value = {
    primary   = { for k, v in aws_eip.primary : k => v.public_ip }
    secondary = { for k, v in aws_eip.secondary : k => v.public_ip }
  }
}

output "instance_ids" {
  description = "Gateway EC2 instance IDs."
  value = {
    primary   = aws_instance.primary.id
    secondary = try(aws_instance.secondary[0].id, null)
  }
}

locals {
  gre_primary = <<-EOT

    ###########################################################################################
    Run these steps on the PRIMARY Netskope SD-WAN gateway to create the GRE tunnel to Cloud WAN
    ###########################################################################################

    1) Configure the GRE tunnel

        infhostd config-gre -inside-ip ${local.primary_peer.inside_ip} \
          -inside-mask ${cidrnetmask(var.cloudwan.primary_inside_cidr)} \
          -intfname gre1 \
          -local-ip ${tolist(aws_network_interface.primary[local.primary_lan_interface].private_ips)[0]} \
          -remote-ip ${local.primary_peer.gre_remote_ip} \
          -mtu 1300 \
          -phy-intfname ens6

    2) Restart the services

        service infhost restart
        infhostd restart-container
  EOT

  gre_secondary = local.ha ? join("\n", [
    "",
    "###############################################################################",
    "Repeat on the SECONDARY (HA) gateway:",
    "###############################################################################",
    "",
    "    infhostd config-gre -inside-ip ${local.secondary_peer.inside_ip} \\",
    "      -inside-mask ${cidrnetmask(var.cloudwan.secondary_inside_cidr)} \\",
    "      -intfname gre1 \\",
    "      -local-ip ${tolist(aws_network_interface.secondary[local.secondary_lan_interface].private_ips)[0]} \\",
    "      -remote-ip ${local.secondary_peer.gre_remote_ip} \\",
    "      -mtu 1300 \\",
    "      -phy-intfname ens6",
    "",
    "    service infhost restart",
    "    infhostd restart-container",
  ]) : null
}

output "primary_gw_gre_config" {
  description = "Manual GRE commands for the legacy (portal API) gateway. Null in console mode."
  value       = local.portal ? local.gre_primary : null
}

output "secondary_gw_gre_config" {
  description = "Manual GRE commands for the secondary (HA) legacy gateway. Null in console mode."
  value       = local.portal ? local.gre_secondary : null
}

output "gateway_private_ips" {
  description = "Private IPs of the gateway interfaces (geN) - use them when configuring the gateway in the Netskope console."
  value = {
    primary   = { for k, v in aws_network_interface.primary : k => tolist(v.private_ips)[0] }
    secondary = { for k, v in aws_network_interface.secondary : k => tolist(v.private_ips)[0] }
  }
}

output "cloudwan_connect_details" {
  description = "Values to configure the GRE tunnel + BGP session in the Netskope console (Cloud WAN side of the Connect peer)."
  value = {
    primary = {
      gre_local_ip       = tolist(aws_network_interface.primary[local.primary_lan_interface].private_ips)[0]
      gre_remote_ip      = local.primary_peer.gre_remote_ip
      inside_cidr        = var.cloudwan.primary_inside_cidr
      gateway_inside_ip  = local.primary_peer.inside_ip
      bgp_neighbors      = local.primary_peer.bgp_neighbors
      cloud_wan_asn      = var.cloudwan.core_network_asn
      netskope_bgp_asn   = var.tenant.tenant_bgp_asn
      connect_attachment = aws_networkmanager_connect_attachment.this.id
      suggested_gre_mtu  = 1300
    }
    secondary = local.ha ? {
      gre_local_ip       = tolist(aws_network_interface.secondary[local.secondary_lan_interface].private_ips)[0]
      gre_remote_ip      = local.secondary_peer.gre_remote_ip
      inside_cidr        = var.cloudwan.secondary_inside_cidr
      gateway_inside_ip  = local.secondary_peer.inside_ip
      bgp_neighbors      = local.secondary_peer.bgp_neighbors
      cloud_wan_asn      = var.cloudwan.core_network_asn
      netskope_bgp_asn   = var.tenant.tenant_bgp_asn
      connect_attachment = aws_networkmanager_connect_attachment.this.id
      suggested_gre_mtu  = 1300
    } : null
  }
}
