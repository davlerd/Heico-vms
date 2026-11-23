### CLOUD WAN

output "global_network_id" {
  description = "Cloud WAN global network ID."
  value       = module.cloudwan.global_network_id
}

output "core_network_id" {
  description = "Cloud WAN core network ID."
  value       = module.cloudwan.core_network_id
}

output "core_network_arn" {
  description = "Cloud WAN core network ARN."
  value       = module.cloudwan.core_network_arn
}

output "cloudwan_attachment_ids" {
  description = "Cloud WAN VPC attachments created for the VPCs of this stack, by key of `cloudwan_attachments`."
  value       = { for k, v in aws_networkmanager_vpc_attachment.this : k => v.id }
}

### PALO ALTO

output "vpc_ids" {
  description = "IDs of the VPCs managed through `vpcs` (security VPC and, optionally, spoke VPCs)."
  value       = { for k, v in module.vpc : k => v.id }
}

output "gwlb_endpoint_service_names" {
  description = "GWLB endpoint service names (use them to create GWLB endpoints in spoke VPCs of other accounts)."
  value       = { for k, v in module.gwlb : k => v.endpoint_service.service_name }
}

output "vmseries_instance_ids" {
  description = "VM-Series EC2 instance IDs."
  value       = { for k, v in module.vmseries : k => v.instance.id }
}

output "vmseries_public_ips" {
  description = "VM-Series public IPs (management / public interfaces with an EIP), by instance."
  value       = { for k, v in module.vmseries : k => v.public_ips }
}

### NETSKOPE

output "netskope_vpc_id" {
  description = "ID of the dedicated Netskope SD-WAN VPC."
  value       = try(module.netskope_sdwan[0].vpc_id, null)
}

output "netskope_gateway_public_ips" {
  description = "EIPs of the Netskope SD-WAN gateway WAN interfaces."
  value       = try(module.netskope_sdwan[0].gateway_public_ips, null)
}

output "netskope_connect_attachment_id" {
  description = "Cloud WAN Connect attachment of the Netskope SD-WAN gateway."
  value       = try(module.netskope_sdwan[0].connect_attachment_id, null)
}

output "netskope_gateway_private_ips" {
  description = "Private IPs of the Netskope gateway interfaces (geN)."
  value       = try(module.netskope_sdwan[0].gateway_private_ips, null)
}

output "netskope_cloudwan_connect_details" {
  description = "GRE / BGP values to enter in the Netskope console (console mode) - Cloud WAN side of the Connect peer."
  value       = try(module.netskope_sdwan[0].cloudwan_connect_details, null)
}

output "netskope_primary_gw_gre_config" {
  description = "Legacy (portal_automation = true) GRE commands to run on the primary Netskope gateway. Null in console mode."
  value       = try(module.netskope_sdwan[0].primary_gw_gre_config, null)
}

output "netskope_secondary_gw_gre_config" {
  description = "Manual GRE configuration to run on the secondary (HA) Netskope gateway."
  value       = try(module.netskope_sdwan[0].secondary_gw_gre_config, null)
}
