###############################################################################
# AWS CLOUD WAN
#
# Global network + core network + core network policy. The core network is the
# hub that replaces the Transit Gateway of the original PAN "combined design":
#   * Security VPC (VM-Series + GWLB)  -> VPC attachment, member of the network
#                                         function group (NFG) used for service insertion
#   * SD-WAN VPC (Netskope GW)          -> VPC attachment (transport) + Connect
#                                         attachment (GRE/BGP) in the "sdwan" segment
###############################################################################

locals {
  # One edge per region. If not given, a single edge in var.region.
  cloudwan_edge_locations = coalesce(var.cloudwan.edge_locations, [{
    location = var.region
    asn      = tonumber(split("-", var.cloudwan.asn_ranges[0])[0])
  }])

  # ASN of the Cloud WAN edge in the region where Netskope connects (BGP remote-as).
  cloudwan_local_edge_asn = one([for e in local.cloudwan_edge_locations : e.asn if e.location == var.region])

  # Attachments are mapped to segments / NFG by tag (attachment policy below).
  cloudwan_segment_tag_key = "segment"
  cloudwan_nfg_tag_key     = "nfg"

  # send-via pairs: { from => [to, ...] }
  cloudwan_inspection_pairs = flatten([
    for from, tos in var.cloudwan.east_west_inspection : [for to in tos : { from = from, to = to }]
  ])
}

data "aws_networkmanager_core_network_policy_document" "this" {
  core_network_configuration {
    vpn_ecmp_support   = var.cloudwan.vpn_ecmp_support
    asn_ranges         = var.cloudwan.asn_ranges
    inside_cidr_blocks = var.cloudwan.inside_cidr_blocks

    dynamic "edge_locations" {
      for_each = local.cloudwan_edge_locations
      content {
        location = edge_locations.value.location
        asn      = edge_locations.value.asn
      }
    }
  }

  dynamic "segments" {
    for_each = var.cloudwan.segments
    content {
      name                          = segments.key
      description                   = "Segment ${segments.key}"
      require_attachment_acceptance = false
      isolate_attachments           = segments.value.isolate_attachments
    }
  }

  network_function_groups {
    name                          = var.cloudwan.network_function_group_name
    description                   = "Palo Alto Networks VM-Series inspection VPCs"
    require_attachment_acceptance = false
  }

  # East-west: traffic between two segments is sent through the NFG (firewall).
  dynamic "segment_actions" {
    for_each = local.cloudwan_inspection_pairs
    content {
      action  = "send-via"
      segment = segment_actions.value.from
      mode    = "single-hop"
      when_sent_to {
        segments = [segment_actions.value.to]
      }
      via {
        network_function_groups = [var.cloudwan.network_function_group_name]
      }
    }
  }

  # North-south: internet-bound traffic of the segment is sent through the NFG (firewall + egress NAT).
  dynamic "segment_actions" {
    for_each = toset(var.cloudwan.internet_egress_segments)
    content {
      action  = "send-to"
      segment = segment_actions.value
      via {
        network_function_groups = [var.cloudwan.network_function_group_name]
      }
    }
  }

  # Segment attachments, selected by tag.
  dynamic "attachment_policies" {
    for_each = { for i, s in sort(keys(var.cloudwan.segments)) : s => i }
    content {
      rule_number     = 100 + attachment_policies.value
      condition_logic = "and"
      conditions {
        type     = "tag-value"
        operator = "equals"
        key      = local.cloudwan_segment_tag_key
        value    = attachment_policies.key
      }
      action {
        association_method = "constant"
        segment            = attachment_policies.key
      }
    }
  }

  # NFG attachments (Palo Alto security VPC), selected by tag.
  attachment_policies {
    rule_number     = 900
    condition_logic = "and"
    conditions {
      type     = "tag-value"
      operator = "equals"
      key      = local.cloudwan_nfg_tag_key
      value    = var.cloudwan.network_function_group_name
    }
    action {
      add_to_network_function_group = var.cloudwan.network_function_group_name
    }
  }
}

module "cloudwan" {
  source = "./modules/cloudwan"

  global_network = {
    description = var.cloudwan.global_network_description
  }

  core_network = {
    description     = var.cloudwan.core_network_description
    policy_document = data.aws_networkmanager_core_network_policy_document.this.json
  }

  tags = var.global_tags
}
