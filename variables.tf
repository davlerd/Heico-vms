### GENERAL

variable "region" {
  description = "AWS region where the security VPC, the SD-WAN VPC and the Cloud WAN edge are deployed."
  type        = string
  default     = "us-west-2"
}

variable "name_prefix" {
  description = "Prefix used in the names of the resources (VPCs, EC2 instances, load balancers, IAM, ...)."
  type        = string
  default     = ""
}

variable "global_tags" {
  description = "Tags applied to all provisioned resources."
  type        = map(string)
  default     = {}
}

variable "ssh_key_name" {
  description = "Name of an existing EC2 key pair used to authenticate to the VM-Series and to the Netskope SD-WAN gateway."
  type        = string
}

variable "address_space" {
  description = <<-EOF
    Address block assigned to this deployment (e.g. 10.103.0.0/16). When set, every VPC in `vpcs`, the Netskope
    VPC and `cloudwan.inside_cidr_blocks` must fall inside it (checked at plan time).
  EOF
  type        = string
  default     = null

  validation {
    condition     = var.address_space == null || can(cidrhost(var.address_space, 0))
    error_message = "address_space must be a valid IPv4 CIDR block."
  }
}

### CLOUD WAN

variable "cloudwan" {
  description = <<-EOF
    AWS Cloud WAN definition (global network, core network and core network policy).

    - `global_network_description`, `core_network_description`: descriptions.
    - `asn_ranges`: ASN range(s) the edges draw from (private ASN, 16 or 32 bit).
    - `inside_cidr_blocks`: /24 (or larger) range(s) used for the Cloud WAN side of the Connect (GRE) tunnels.
      They must NOT overlap any VPC or on-premises range, and are routed to the core network from the SD-WAN VPC.
    - `edge_locations`: list of `{ location, asn }`. Default: one edge in `var.region` with the first ASN of `asn_ranges`.
    - `vpn_ecmp_support`: ECMP across Site-to-Site VPN / Connect peers.
    - `segments`: map of segment name => `{ isolate_attachments }`. The SD-WAN VPC joins the segment given in `netskope.cloudwan.segment`.
    - `network_function_group_name`: NFG that holds the firewall VPC attachment(s) (service insertion).
    - `east_west_inspection`: map `segment => [segments]`; traffic between each pair goes through the firewall (`send-via`, single-hop).
    - `internet_egress_segments`: segments whose internet-bound traffic goes through the firewall (`send-to`).
  EOF
  type = object({
    global_network_description = optional(string, "Global network")
    core_network_description   = optional(string, "Core network")
    asn_ranges                 = optional(list(string), ["64520-64525"])
    inside_cidr_blocks         = list(string)
    edge_locations = optional(list(object({
      location = string
      asn      = number
    })))
    vpn_ecmp_support = optional(bool, true)
    segments = optional(map(object({
      isolate_attachments = optional(bool, false)
    })), { workloads = {}, sdwan = {} })
    network_function_group_name = optional(string, "paloalto")
    east_west_inspection        = optional(map(list(string)), { sdwan = ["workloads"] })
    internet_egress_segments    = optional(list(string), ["workloads", "sdwan"])
  })

  validation {
    condition     = alltrue([for c in var.cloudwan.inside_cidr_blocks : can(cidrhost(c, 0))])
    error_message = "cloudwan.inside_cidr_blocks must contain valid IPv4 CIDR blocks."
  }
  validation {
    condition = alltrue(flatten([
      [for s, tos in var.cloudwan.east_west_inspection : contains(keys(var.cloudwan.segments), s)],
      [for s, tos in var.cloudwan.east_west_inspection : [for t in tos : contains(keys(var.cloudwan.segments), t)]],
      [for s in var.cloudwan.internet_egress_segments : contains(keys(var.cloudwan.segments), s)],
    ]))
    error_message = "cloudwan.east_west_inspection and cloudwan.internet_egress_segments must only reference segments defined in cloudwan.segments."
  }
}

variable "cloudwan_attachments" {
  description = <<-EOF
    Cloud WAN VPC attachments for VPCs defined in `vpcs` (replaces `tgw_attachments` of the original design).

    - `name`: attachment name.
    - `vpc`: key of the VPC in `vpcs`.
    - `subnet_group`: subnet group (one subnet per AZ) used for the attachment.
    - `segment`: segment the attachment joins (for spoke VPCs). Mutually exclusive with `network_function_group`.
    - `network_function_group`: `true` to join the NFG (the firewall VPC). Mutually exclusive with `segment`.
    - `appliance_mode_support`: keeps both directions of a flow in the same AZ. Must be `true` for the firewall VPC.
    - `ipv6_support`, `tags`: optional.

    Example:
    ```
    cloudwan_attachments = {
      security = {
        name                   = "security-vpc"
        vpc                    = "security_vpc"
        subnet_group           = "cloudwan_attach"
        network_function_group = true
        appliance_mode_support = true
      }
    }
    ```
  EOF
  type = map(object({
    name                   = string
    vpc                    = string
    subnet_group           = string
    segment                = optional(string)
    network_function_group = optional(bool, false)
    appliance_mode_support = optional(bool, false)
    ipv6_support           = optional(bool, false)
    tags                   = optional(map(string), {})
  }))
  default = {}

  validation {
    condition     = alltrue([for k, v in var.cloudwan_attachments : (v.segment != null) != v.network_function_group])
    error_message = "Each Cloud WAN attachment must set exactly one of `segment` or `network_function_group = true`."
  }
  validation {
    condition     = alltrue([for k, v in var.cloudwan_attachments : !v.network_function_group || v.appliance_mode_support])
    error_message = "Attachments in the network function group (firewall VPC) must set appliance_mode_support = true."
  }
  validation {
    condition     = alltrue([for k, v in var.cloudwan_attachments : v.segment == null || contains(keys(var.cloudwan.segments), v.segment)])
    error_message = "Attachment `segment` must exist in cloudwan.segments."
  }
}

### VPC
variable "vpcs" {
  description = <<-EOF
    A map defining VPCs with security groups and subnets.

    Following properties are available:
    - `name`: VPC name
    - `cidr`: CIDR for VPC
    - `security_groups`: map of security groups
    - `subnets`: map of subnets with properties:
        - `az`: availability zone
        - `subnet_group`: identity of the same purpose subnets group such as management
    - `routes`: map of routes with properties:
        - `vpc`: key of the VPC
        - `subnet_group`: key of the subnet group
        - `next_hop_key`: must match keys used to create Cloud WAN attachment, IGW, GWLB endpoint or other resources
        - `next_hop_type`: internet_gateway, core_network_attachment (key of `cloudwan_attachments`) or gwlbe_endpoint

    Example:
    ```
    vpcs = {
      example_vpc = {
        name = "example-spoke-vpc"
        cidr = "10.104.0.0/16"
        nacls = {
          trusted_path_monitoring = {
            name               = "trusted-path-monitoring"
            rules = {
              allow_inbound = {
                rule_number = 300
                egress      = false
                protocol    = "-1"
                rule_action = "allow"
                cidr_block  = "0.0.0.0/0"
                from_port   = null
                to_port     = null
              }
            }
          }
        }
        security_groups = {
          example_vm = {
            name = "example_vm"
            rules = {
              all_outbound = {
                description = "Permit All traffic outbound"
                type        = "egress", from_port = "0", to_port = "0", protocol = "-1"
                cidr_blocks = ["0.0.0.0/0"]
              }
            }
          }
        }
        subnets = {
          "10.104.0.0/24"   = { az = "eu-central-1a", subnet_group = "vm", nacl = null }
          "10.104.128.0/24" = { az = "eu-central-1b", subnet_group = "vm", nacl = null }
        }
        routes = {
          vm_default = {
            vpc           = "app1_vpc"
            subnet_group        = "app1_vm"
            to_cidr       = "0.0.0.0/0"
            next_hop_key  = "app1"
            next_hop_type = "core_network_attachment"
          }
        }
      }
    }
    ```
    EOF
  default     = {}
  type = map(object({
    name                             = string
    create_vpc                       = optional(bool, true)
    cidr                             = string
    secondary_cidr_blocks            = optional(list(string), [])
    assign_generated_ipv6_cidr_block = optional(bool)
    use_internet_gateway             = optional(bool, false)
    name_internet_gateway            = optional(string)
    create_internet_gateway          = optional(bool, true)
    route_table_internet_gateway     = optional(string)
    create_vpn_gateway               = optional(bool, false)
    vpn_gateway_amazon_side_asn      = optional(string)
    name_vpn_gateway                 = optional(string)
    route_table_vpn_gateway          = optional(string)
    enable_dns_hostnames             = optional(bool, true)
    enable_dns_support               = optional(bool, true)
    instance_tenancy                 = optional(string, "default")
    nacls = optional(map(object({
      name = string
      rules = map(object({
        rule_number = number
        egress      = bool
        protocol    = string
        rule_action = string
        cidr_block  = string
        from_port   = optional(number)
        to_port     = optional(number)
      }))
    })), {})
    security_groups = optional(map(object({
      name = string
      rules = map(object({
        description            = optional(string)
        type                   = string
        cidr_blocks            = optional(list(string))
        ipv6_cidr_blocks       = optional(list(string))
        from_port              = string
        to_port                = string
        protocol               = string
        prefix_list_ids        = optional(list(string))
        source_security_groups = optional(list(string))
        self                   = optional(bool)
      }))
    })), {})
    subnets = optional(map(object({
      name                    = optional(string, "")
      az                      = string
      subnet_group            = string
      nacl                    = optional(string)
      create_subnet           = optional(bool, true)
      create_route_table      = optional(bool, true)
      existing_route_table_id = optional(string)
      route_table_name        = optional(string)
      associate_route_table   = optional(bool, true)
      local_tags              = optional(map(string), {})
      map_public_ip_on_launch = optional(bool, false)
    })), {})
    routes = optional(map(object({
      vpc                    = string
      subnet_group           = string
      to_cidr                = string
      next_hop_key           = string
      next_hop_type          = string
      destination_type       = optional(string, "ipv4")
      managed_prefix_list_id = optional(string)
    })), {})
    create_dhcp_options = optional(bool, false)
    domain_name         = optional(string)
    domain_name_servers = optional(list(string))
    ntp_servers         = optional(list(string))
    vpc_tags            = optional(map(string), {})
  }))
}

### GATEWAY LOADBALANCER
variable "gwlbs" {
  description = <<-EOF
  A map defining Gateway Load Balancers.

  Following properties are available:
  - `name`: name of the GWLB
  - `vpc`: key of the VPC
  - `subnet_group`: key of the subnet_group

  Example:
  ```
  gwlbs = {
    security_gwlb = {
      name   = "security-gwlb"
      vpc    = "security_vpc"
      subnet_group = "gwlb"
    }
  }
  ```
  EOF
  default     = {}
  type = map(object({
    name         = string
    vpc          = string
    subnet_group = string
    tg_name      = optional(string)
    target_instances = optional(map(object({
      id = string
    })), {})
    acceptance_required           = optional(bool, false)
    allowed_principals            = optional(list(string), [])
    deregistration_delay          = optional(number)
    health_check_enabled          = optional(bool)
    health_check_interval         = optional(number, 5)
    health_check_matcher          = optional(string)
    health_check_path             = optional(string)
    health_check_port             = optional(number, 80)
    health_check_protocol         = optional(string)
    health_check_timeout          = optional(number)
    healthy_threshold             = optional(number, 3)
    unhealthy_threshold           = optional(number, 3)
    stickiness_type               = optional(string)
    rebalance_flows               = optional(string, "no_rebalance")
    lb_tags                       = optional(map(string), {})
    lb_target_group_tags          = optional(map(string), {})
    endpoint_service_tags         = optional(map(string), {})
    enable_lb_deletion_protection = optional(bool)
  }))
}

variable "gwlb_endpoints" {
  description = <<-EOF
    A map defining GWLB endpoints.

    Following properties are available:
    - `name`: name of the GWLB endpoint
    - `custom_names`: Optional map of names of the VPC Endpoints, used to override the default naming generated from the input `name`.
      Each key is the Availability Zone identifier, for example `us-east-1b`.
    - `gwlb`: key of GWLB. Required when GWLB Endpoint must connect to GWLB's service name
    - `vpc`: key of VPC
    - `subnet_group`: key of the subnet_group
    - `act_as_next_hop`: set to `true` if endpoint is part of an IGW route table e.g. for inbound traffic
    - `from_igw_to_vpc`: VPC to which traffic from IGW is routed to the GWLB endpoint
    - `from_igw_to_subnet_group` : subnet_group to which traffic from IGW is routed to the GWLB endpoint
    - `cloudngfw_key`(optional): Key of the Cloud NGFW. Required when GWLB Endpoint must connect to Cloud NGFW's service name

    Example:
    ```
    gwlb_endpoints = {
      security_gwlb_eastwest = {
        name            = "eastwest-gwlb-endpoint"
        gwlb            = "security_gwlb"
        vpc             = "security_vpc"
        subnet_group    = "gwlbe_eastwest"
        act_as_next_hop = false
      }
    }
    ```
    EOF
  default     = {}
  type = map(object({
    name                     = string
    custom_names             = optional(map(string), {})
    gwlb                     = optional(string)
    vpc                      = string
    subnet_group             = string
    act_as_next_hop          = bool
    from_igw_to_vpc          = optional(string)
    from_igw_to_subnet_group = optional(string)
    delay                    = optional(number, 0)
    tags                     = optional(map(string))
    cloudngfw_key            = optional(string)
  }))
}

### VM-SERIES
variable "vmseries" {
  description = <<-EOF
  A map defining VM-Series instances

  Following properties are available:
  - `instances`: map of VM-Series instances
  - `bootstrap_options`: VM-Seriess bootstrap options used to connect to Panorama
  - `panos_version`: PAN-OS version used for VM-Series
  - `airs_deployment (optional|false)`: flag to deploy AIRS product type 
  - `ebs_kms_id`: alias for AWS KMS used for EBS encryption in VM-Series
  - `ebs_volume_type`: type of EBS volume used
  - `vpc`: key of VPC
  - `gwlb`: key of GWLB
  - `subinterfaces`: configuration of network subinterfaces used to map with GWLB endpoints
  - `system_services`: map of system services
  - `application_lb`: ALB placed in front of the Firewalls' public interfaces
  - `network_lb`: NLB placed in front of the Firewalls' public interfaces

  Example:
  ```
  vmseries = {
    vmseries = {
      instances = {
        "01" = { az = "eu-central-1a" }
        "02" = { az = "eu-central-1b" }
      }

      # Value of `panorama-server`, `auth-key`, `dgname`, `tplname` can be taken from plugin `sw_fw_license`
      bootstrap_options = {
        mgmt-interface-swap         = "enable"
        plugin-op-commands          = "panorama-licensing-mode-on,aws-gwlb-inspect:enable,aws-gwlb-overlay-routing:enable"
        dhcp-send-hostname          = "yes"
        dhcp-send-client-id         = "yes"
        dhcp-accept-server-hostname = "yes"
        dhcp-accept-server-domain   = "yes"
      }

      panos_version   = "11.2.8"
      ebs_kms_id      = "alias/aws/ebs"
      ebs_volume_type = "gp3"

      # Value of `vpc` must match key of objects stored in `vpcs`
      vpc = "security_vpc"

      # Value of `gwlb` must match key of objects stored in `gwlbs`
      gwlb = "security_gwlb"

      interfaces = {
        private = {
          device_index      = 0
          security_group    = "vmseries_private"
          vpc               = "security_vpc"
          subnet_group            = "private"
          create_public_ip  = false
          source_dest_check = false
        }
        mgmt = {
          device_index      = 1
          security_group    = "vmseries_mgmt"
          vpc               = "security_vpc"
          subnet_group            = "mgmt"
          create_public_ip  = true
          source_dest_check = true
        }
        public = {
          device_index      = 2
          security_group    = "vmseries_public"
          vpc               = "security_vpc"
          subnet_group            = "public"
          create_public_ip  = true
          source_dest_check = false
        }
      }

      # Value of `gwlb_endpoint` must match key of objects stored in `gwlb_endpoints`
      subinterfaces = {
        inbound = {
          app1 = {
            gwlb_endpoint = "app1_inbound"
            subinterface  = "ethernet1/1.11"
          }
          app2 = {
            gwlb_endpoint = "app2_inbound"
            subinterface  = "ethernet1/1.12"
          }
        }
        outbound = {
          only_1_outbound = {
            gwlb_endpoint = "security_gwlb_outbound"
            subinterface  = "ethernet1/1.20"
          }
        }
        eastwest = {
          only_1_eastwest = {
            gwlb_endpoint = "security_gwlb_eastwest"
            subinterface  = "ethernet1/1.30"
          }
        }
      }

      system_services = {
        dns_primary = "4.2.2.2"      # TODO: update here
        dns_secondy = null           # TODO: update here
        ntp_primary = "pool.ntp.org" # TODO: update here
        ntp_secondy = null           # TODO: update here
      }
    }
  }
  ```
  EOF
  default     = {}
  type = map(object({
    instances = map(object({
      az   = string
      name = optional(string)
    }))

    bootstrap_options = object({
      hostname                              = optional(string)
      mgmt-interface-swap                   = string
      plugin-op-commands                    = string
      op-command-modes                      = optional(string)
      panorama-server                       = string
      panorama-server-2                     = optional(string)
      auth-key                              = optional(string)
      vm-auth-key                           = optional(string)
      dgname                                = string
      tplname                               = optional(string)
      cgname                                = optional(string)
      dns-primary                           = optional(string)
      dns-secondary                         = optional(string)
      dhcp-send-hostname                    = optional(string)
      dhcp-send-client-id                   = optional(string)
      dhcp-accept-server-hostname           = optional(string)
      dhcp-accept-server-domain             = optional(string)
      authcodes                             = optional(string)
      vm-series-auto-registration-pin-id    = optional(string)
      vm-series-auto-registration-pin-value = optional(string)
    })

    panos_version                          = string
    airs_deployment                        = optional(bool, false)
    arm_deployment                         = optional(bool, false)
    ebs_kms_id                             = string
    ebs_volume_type                        = optional(string, "gp3")
    vmseries_ami_id                        = optional(string)
    vmseries_product_code                  = optional(string, "6njl1pau431dv1qxipg63mvah")
    include_deprecated_ami                 = optional(bool, false)
    instance_type                          = optional(string, "m5.xlarge")
    ebs_encrypted                          = optional(bool, true)
    enable_instance_termination_protection = optional(bool, false)
    enable_monitoring                      = optional(bool, false)
    fw_license_type                        = optional(string, "byol")

    vpc  = string
    gwlb = optional(string)

    interfaces = map(object({
      device_index       = number
      name               = optional(string)
      description        = optional(string)
      security_group     = string
      subnet_group       = string
      create_public_ip   = optional(bool, false)
      eip_allocation_id  = optional(string)
      source_dest_check  = optional(bool, false)
      private_ips        = optional(list(string))
      ipv6_address_count = optional(number, null)
      public_ipv4_pool   = optional(string)
    }))

    subinterfaces = map(map(object({
      gwlb_endpoint = string
      subinterface  = string
    })))

    tags = optional(map(string))

    system_services = object({
      dns_primary = string
      dns_secondy = optional(string)
      ntp_primary = string
      ntp_secondy = optional(string)
    })

    application_lb = optional(object({
      name           = optional(string)
      subnet_group   = optional(string)
      security_group = optional(string)
      rules          = optional(any)
    }), {})

    network_lb = optional(object({
      name         = optional(string)
      subnet_group = optional(string)
      rules        = optional(any)
    }), {})
  }))
}

variable "bootstrap_secrets" {
  description = <<-EOF
    Sensitive VM-Series bootstrap options appended to `vmseries.<group>.bootstrap_options` (kept out of the tfvars file),
    e.g. `auth-key`, `vm-auth-key`, `authcodes`, `vm-series-auto-registration-pin-value`.
    Pass them with `TF_VAR_bootstrap_secrets='{"auth-key":"..."}'` or in an untracked `secrets.auto.tfvars`.
  EOF
  type        = map(string)
  default     = {}
  sensitive   = true
}

### NETSKOPE SD-WAN GATEWAY

variable "netskope_api_token" {
  description = "Netskope Borderless SD-WAN REST API token (Portal > Settings > Administration > API Tokens)."
  type        = string
  default     = ""
  sensitive   = true
}

variable "netskope_gateway_password" {
  description = "Optional gateway password set through cloud-init (console access; SSH password login only if netskope.ssh_password_auth = true)."
  type        = string
  default     = ""
  sensitive   = true
}

variable "netskope" {
  description = <<-EOF
    Netskope gateway deployed in its OWN VPC (never the firewall VPC) and connected to Cloud WAN with a
    VPC (transport) attachment plus a Connect attachment (GRE + BGP).

    - `enabled`: set `false` to skip the whole Netskope deployment.
    - `portal_automation`: `false` (default) = infrastructure only, the gateway is activated and configured from the
      Netskope console (flow of the greenfield template downloaded from the console). `true` = legacy API flow: Terraform
      also creates the policy / gateway / interfaces / BGP in the portal (netskopebwan provider) and bootstraps the gateway.
    - `tenant`: `tenant_bgp_asn` is the BGP ASN of the gateway (always used for the Cloud WAN Connect peer);
      `tenant_id` and `tenant_url` (e.g. https://example.infiot.net) are only needed with `portal_automation = true`.
    - `vpc`: `cidr`, optional `name` / `primary_zone` / `secondary_zone`, and the subnets of every gateway interface
      (`primary_gw_subnets`, `secondary_gw_subnets` - the latter is used only with HA). `ge1` is the WAN interface
      (`overlay = "public"` -> EIP). An interface without `overlay` is a LAN interface: it hosts the Cloud WAN
      attachment and the GRE tunnel. `private_ip` (optional) fixes the IP of the interface inside its subnet.
    - `cloudwan`: `segment` the SD-WAN VPC + Connect attachments join, and the /29 BGP inside CIDRs of the GRE peers
      (from 169.254.0.0/16, unique per peer).
    - `gateway`: `ha_enabled`; portal objects and DNS servers (`gateway_name`, `gateway_policy`, `gateway_model`,
      `gateway_role`, `dns_*`) are only used with `portal_automation = true`.
    - `instance`: `instance_type` (c5.xlarge), `ami_id` (required in console mode; wins over the `ami_name` lookup),
      `root_volume_size` (null = size of the AMI snapshot; the R6.3.x gateway AMI needs at least 80 GB, a smaller value
      fails with InvalidBlockDeviceMapping) / `root_volume_type` (gp3).
    - `ssh_allowed_cidrs` / `https_allowed_cidrs`: CIDRs allowed to reach TCP 22 / 443 on the WAN interface (empty = closed).
    - `ssh_password_auth`: enable SSH password login via cloud-init (needs `netskope_gateway_password`).
  EOF
  type = object({
    enabled           = optional(bool, true)
    portal_automation = optional(bool, false)
    tenant = optional(object({
      tenant_id      = optional(string, "")
      tenant_url     = optional(string, "")
      tenant_bgp_asn = optional(string, "400")
    }), {})
    vpc = object({
      name           = optional(string, "sdwan-vpc")
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
    cloudwan = optional(object({
      segment               = optional(string, "sdwan")
      primary_inside_cidr   = optional(string, "169.254.100.0/29")
      secondary_inside_cidr = optional(string, "169.254.100.8/29")
    }), {})
    gateway = optional(object({
      ha_enabled     = optional(bool, false)
      gateway_name   = optional(string, "aws-sdwan-gw")
      gateway_policy = optional(string, "aws-sdwan-gw")
      gateway_model  = optional(string, "iXVirtual")
      gateway_role   = optional(string, "spoke")
      dns_primary    = optional(string, "8.8.8.8")
      dns_secondary  = optional(string, "8.8.4.4")
    }), {})
    instance = optional(object({
      instance_type    = optional(string, "c5.xlarge")
      ami_id           = optional(string)
      ami_name         = optional(string, "Infiot-Edge_R1.4.109")
      ami_owner        = optional(string, "aws-marketplace")
      root_volume_size = optional(number) # null = size of the AMI snapshot (the R6.3.x gateway AMI needs >= 80 GB)
      root_volume_type = optional(string, "gp3")
    }), {})
    ssh_allowed_cidrs   = optional(list(string), [])
    https_allowed_cidrs = optional(list(string), [])
    ssh_password_auth   = optional(bool, false)
  })

  validation {
    condition     = !var.netskope.enabled || (var.netskope.gateway.gateway_role == "spoke" || var.netskope.gateway.gateway_role == "hub")
    error_message = "netskope.gateway.gateway_role must be \"spoke\" or \"hub\"."
  }
  validation {
    condition     = !var.netskope.enabled || !var.netskope.gateway.ha_enabled || var.netskope.vpc.secondary_gw_subnets != null
    error_message = "netskope.vpc.secondary_gw_subnets is required when netskope.gateway.ha_enabled = true."
  }
  validation {
    condition     = !var.netskope.enabled || var.netskope.portal_automation || var.netskope.instance.ami_id != null
    error_message = "netskope.instance.ami_id (Netskope gateway AMI from the console / Marketplace) is required unless netskope.portal_automation = true."
  }
  validation {
    condition     = !var.netskope.enabled || !var.netskope.portal_automation || (var.netskope.tenant.tenant_id != "" && var.netskope.tenant.tenant_url != "")
    error_message = "netskope.tenant.tenant_id and tenant_url are required when netskope.portal_automation = true."
  }
  validation {
    condition     = !var.netskope.enabled || !var.netskope.ssh_password_auth || var.netskope_gateway_password != ""
    error_message = "netskope.ssh_password_auth = true requires netskope_gateway_password."
  }
  validation {
    condition     = !var.netskope.enabled || length([for k, v in var.netskope.vpc.primary_gw_subnets : k if v != null && v.overlay != "public"]) > 0
    error_message = "netskope.vpc.primary_gw_subnets needs a LAN interface (an interface whose overlay is not \"public\", e.g. ge2): it hosts the Cloud WAN attachment and the GRE tunnel."
  }
  validation {
    condition     = !var.netskope.enabled || contains(keys(var.cloudwan.segments), var.netskope.cloudwan.segment)
    error_message = "netskope.cloudwan.segment must exist in cloudwan.segments."
  }
}
