###############################################################################
# NETSKOPE SD-WAN GATEWAY
#
# Deployed in its own VPC (created by the module), never in the firewall VPC, and
# connected to Cloud WAN with a VPC + Connect (GRE/BGP) attachment in the SD-WAN segment.
###############################################################################

module "netskope_sdwan" {
  source = "./modules/netskope_sdwan"
  count  = var.netskope.enabled ? 1 : 0

  name_prefix  = var.name_prefix
  tags         = var.global_tags
  ssh_key_name = var.ssh_key_name

  tenant            = var.netskope.tenant
  portal_automation = var.netskope.portal_automation
  vpc               = var.netskope.vpc
  gateway           = var.netskope.gateway
  instance          = var.netskope.instance

  gateway_password    = var.netskope_gateway_password
  ssh_allowed_cidrs   = var.netskope.ssh_allowed_cidrs
  https_allowed_cidrs = var.netskope.https_allowed_cidrs
  ssh_password_auth   = var.netskope.ssh_password_auth

  cloudwan = {
    core_network_id       = module.cloudwan.core_network_id
    core_network_arn      = module.cloudwan.core_network_arn
    core_network_asn      = local.cloudwan_local_edge_asn
    segment               = var.netskope.cloudwan.segment
    segment_tag_key       = local.cloudwan_segment_tag_key
    inside_cidr_blocks    = var.cloudwan.inside_cidr_blocks
    primary_inside_cidr   = var.netskope.cloudwan.primary_inside_cidr
    secondary_inside_cidr = var.netskope.cloudwan.secondary_inside_cidr
  }

  depends_on = [terraform_data.guardrails]
}

###############################################################################
# GUARDRAILS (fail at plan time instead of producing a broken network)
###############################################################################

locals {
  # Every address range that must stay disjoint: VPCs of this stack, the Netskope VPC and the
  # Cloud WAN GRE (inside) CIDRs.
  guard_cidrs = merge(
    { for k, v in var.vpcs : "vpc:${k}" => v.cidr },
    { for k, c in { "netskope-vpc" = var.netskope.vpc.cidr } : k => c if var.netskope.enabled },
    { for i, c in var.cloudwan.inside_cidr_blocks : "cloudwan-inside:${i}" => c },
  )

  # IPv4 range of every CIDR as integers [start, end]
  guard_ranges = { for k, c in local.guard_cidrs : k => {
    start = sum([for i, o in split(".", cidrhost(c, 0)) : tonumber(o) * pow(256, 3 - i)])
    end   = sum([for i, o in split(".", cidrhost(c, -1)) : tonumber(o) * pow(256, 3 - i)])
  } }

  guard_keys = sort(keys(local.guard_ranges))

  # Optional containment in the assigned address block
  guard_space_start = var.address_space == null ? 0 : sum([for i, o in split(".", cidrhost(var.address_space, 0)) : tonumber(o) * pow(256, 3 - i)])
  guard_space_end   = var.address_space == null ? 4294967295 : sum([for i, o in split(".", cidrhost(var.address_space, -1)) : tonumber(o) * pow(256, 3 - i)])
  guard_outside_space = [
    for k in local.guard_keys : "${k} (${local.guard_cidrs[k]})"
    if local.guard_ranges[k].start < local.guard_space_start || local.guard_ranges[k].end > local.guard_space_end
  ]

  # Each unordered pair once (index i < j)
  guard_overlaps = flatten([
    for i, a in local.guard_keys : [
      for j, b in local.guard_keys : "${a} (${local.guard_cidrs[a]}) <-> ${b} (${local.guard_cidrs[b]})"
      if i < j && local.guard_ranges[a].start <= local.guard_ranges[b].end && local.guard_ranges[b].start <= local.guard_ranges[a].end
    ]
  ])
}

resource "terraform_data" "guardrails" {
  lifecycle {
    precondition {
      condition     = length(local.guard_overlaps) == 0
      error_message = "Overlapping address ranges. The Netskope SD-WAN VPC and the Palo Alto security VPC must be different, non-overlapping VPCs, and the Cloud WAN inside CIDRs must not overlap any VPC. Overlaps: ${join("; ", local.guard_overlaps)}"
    }

    precondition {
      condition     = length(local.guard_outside_space) == 0
      error_message = "These ranges are outside address_space (${coalesce(var.address_space, "-")}): ${join("; ", local.guard_outside_space)}"
    }

    precondition {
      condition     = anytrue([for e in local.cloudwan_edge_locations : e.location == var.region])
      error_message = "var.region must be one of the Cloud WAN edge locations (cloudwan.edge_locations)."
    }

    precondition {
      condition     = length([for k, a in var.cloudwan_attachments : k if a.network_function_group]) > 0
      error_message = "At least one Cloud WAN attachment with network_function_group = true (the firewall VPC) is required, otherwise the send-to / send-via policy has no target."
    }
  }
}
