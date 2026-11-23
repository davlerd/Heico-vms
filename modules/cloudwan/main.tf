# --- modules/cloudwan/main.tf ---

locals {
  create_global_network = var.global_network == null ? false : length(keys(var.global_network)) > 0
  create_core_network   = var.core_network == null ? false : length(keys(var.core_network)) > 0
  create_ram_resources  = try(var.core_network.resource_share_name, null) != null
  # to share the core network (global service) use AWS RAM from us-east-1
  ram_global_region = "us-east-1"
}

# ---------- GLOBAL NETWORK ----------
resource "aws_networkmanager_global_network" "global_network" {
  count = local.create_global_network ? 1 : 0

  description = var.global_network.description

  tags = merge(var.tags, try(var.global_network.tags, {}))
}

# ---------- CORE NETWORK ----------
resource "aws_networkmanager_core_network" "core_network" {
  count = local.create_core_network ? 1 : 0

  description = var.core_network.description
  global_network_id = local.create_global_network ? aws_networkmanager_global_network.global_network[0].id : coalesce(
    var.global_network_id,
    "global-network-invalid"
  )

  create_base_policy = true
  base_policy_document = try(var.core_network.base_policy_regions, null) != null ? null : coalesce(
    try(var.core_network.base_policy_document, null),
    jsonencode({
      for k, v in jsondecode(var.core_network.policy_document) : k => v
      if k == "version" || k == "core-network-configuration" || k == "segments"
    })
  )
  base_policy_regions = try(var.core_network.base_policy_regions, null)

  tags = merge(var.tags, try(var.core_network.tags, {}))
}

resource "aws_networkmanager_core_network_policy_attachment" "policy_attachment" {
  count = local.create_core_network ? 1 : 0

  core_network_id = aws_networkmanager_core_network.core_network[0].id
  policy_document = var.core_network.policy_document
}

# ---------- RAM SHARE (CORE NETWORK) ----------
resource "aws_ram_resource_share" "resource_share" {
  count = local.create_ram_resources && local.create_core_network ? 1 : 0

  name                      = var.core_network.resource_share_name
  allow_external_principals = try(var.core_network.resource_share_allow_external_principals, null)
  region                    = local.ram_global_region

  tags = merge(var.tags, try(var.core_network.tags, {}))
}

resource "aws_ram_resource_association" "resource_association" {
  count = local.create_ram_resources && local.create_core_network ? 1 : 0

  resource_arn       = aws_networkmanager_core_network.core_network[0].arn
  resource_share_arn = aws_ram_resource_share.resource_share[0].arn
  region             = local.ram_global_region
}

resource "aws_ram_principal_association" "principal_association" {
  count = local.create_ram_resources && local.create_core_network ? length(try(var.core_network.ram_share_principals, [])) : 0

  principal          = var.core_network.ram_share_principals[count.index]
  resource_share_arn = aws_ram_resource_share.resource_share[0].arn
  region             = local.ram_global_region
}
