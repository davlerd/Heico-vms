variable "name_prefix" {
  description = "Prefix for resource names."
  type        = string
  default     = ""
}

variable "tags" {
  description = "Tags applied to all resources."
  type        = map(string)
  default     = {}
}

variable "ssh_key_name" {
  description = "EC2 key pair for the gateway instance(s)."
  type        = string
}

variable "tenant" {
  description = "Netskope tenant details."
  type = object({
    tenant_id      = string
    tenant_url     = string
    tenant_bgp_asn = string
  })
}

variable "vpc" {
  description = "Dedicated VPC of the SD-WAN gateway(s) and its subnets (one per gateway interface)."
  type = object({
    name           = string
    cidr           = string
    primary_zone   = optional(string)
    secondary_zone = optional(string)
    primary_gw_subnets = object({
      ge1 = object({
        subnet_cidr = string
        overlay     = optional(string, "public")
        private_ip  = optional(string)
      })
      ge2 = optional(object({
        subnet_cidr = string
        overlay     = optional(string)
        private_ip  = optional(string)
      }))
      ge3 = optional(object({
        subnet_cidr = string
        overlay     = optional(string)
        private_ip  = optional(string)
      }))
      ge4 = optional(object({
        subnet_cidr = string
        overlay     = optional(string)
        private_ip  = optional(string)
      }))
    })
    secondary_gw_subnets = optional(object({
      ge1 = object({
        subnet_cidr = string
        overlay     = optional(string, "public")
        private_ip  = optional(string)
      })
      ge2 = optional(object({
        subnet_cidr = string
        overlay     = optional(string)
        private_ip  = optional(string)
      }))
      ge3 = optional(object({
        subnet_cidr = string
        overlay     = optional(string)
        private_ip  = optional(string)
      }))
      ge4 = optional(object({
        subnet_cidr = string
        overlay     = optional(string)
        private_ip  = optional(string)
      }))
    }))
  })
}

variable "cloudwan" {
  description = "Cloud WAN core network the gateway attaches to."
  type = object({
    core_network_id       = string
    core_network_arn      = string
    core_network_asn      = number
    segment               = string
    segment_tag_key       = string
    inside_cidr_blocks    = list(string) # core network side of the GRE tunnels; routed to the core network from this VPC
    primary_inside_cidr   = string       # /29 BGP inside CIDR of the primary gateway
    secondary_inside_cidr = string       # /29 BGP inside CIDR of the secondary gateway
  })
}

variable "gateway" {
  description = "Netskope portal gateway settings."
  type = object({
    ha_enabled     = bool
    gateway_name   = string
    gateway_policy = string
    gateway_model  = string
    gateway_role   = string
    dns_primary    = string
    dns_secondary  = string
  })
}

variable "gateway_password" {
  description = "Optional password of the default `infiot` user (console access only)."
  type        = string
  default     = ""
  sensitive   = true
}

variable "instance" {
  description = "EC2 instance settings of the gateway. `ami_id` wins over the `ami_name` lookup."
  type = object({
    instance_type    = string
    ami_id           = optional(string)
    ami_name         = string
    ami_owner        = string
    root_volume_size = number
    root_volume_type = string
  })
}

variable "portal_automation" {
  description = "true = configure the gateway in the Netskope portal through the netskopebwan provider (legacy API flow). false = infrastructure only; the gateway is activated and configured from the Netskope console."
  type        = bool
}

variable "ssh_password_auth" {
  description = "Allow SSH password authentication (cloud-init) when `gateway_password` is set. Only used when portal_automation = false."
  type        = bool
  default     = false
}

variable "https_allowed_cidrs" {
  description = "CIDRs allowed to reach TCP 443 on the WAN interface. Empty = no rule."
  type        = list(string)
  default     = []
}

variable "ssh_allowed_cidrs" {
  description = "CIDRs allowed to SSH to the WAN interface. Empty = no SSH rule."
  type        = list(string)
  default     = []
}

variable "private_cidrs" {
  description = "Private ranges allowed to reach the LAN interface of the gateway."
  type        = list(string)
  default     = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"]
}
