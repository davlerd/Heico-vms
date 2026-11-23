# --- modules/cloudwan/outputs.tf ---

output "global_network_id" {
  value       = local.create_global_network ? aws_networkmanager_global_network.global_network[0].id : var.global_network_id
  description = "Global Network ID, whether created by this module or supplied by the caller."
}

output "core_network_id" {
  # The ID is only returned after the policy is applied, so consumers (attachments) wait for it.
  value       = local.create_core_network ? aws_networkmanager_core_network_policy_attachment.policy_attachment[0].core_network_id : try(split("/", var.core_network_arn)[1], null)
  description = "Core Network ID, available once the core network policy has been applied."
}

output "core_network_arn" {
  value       = local.create_core_network ? aws_networkmanager_core_network.core_network[0].arn : var.core_network_arn
  description = "Core Network ARN."
}

output "ram_resource_share_arn" {
  value       = local.create_ram_resources && local.create_core_network ? aws_ram_resource_share.resource_share[0].arn : null
  description = "RAM Resource Share ARN when this module creates the share."
}
