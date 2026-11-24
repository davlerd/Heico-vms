# Inputs read by Terraform Cloud (committed on purpose).
# LAB ONLY: this file also holds the SCM auto-registration PIN value and the admin IP.
# For the customer environment move the PIN value to the sensitive variable `bootstrap_secrets`
# (and netskope_gateway_password / netskope_api_token, if used) and keep the repo private.

###############################################################################
# GENERAL
###############################################################################
region = "us-east-1" # TODO: update here. Must be one of the Cloud WAN edge locations.

# Address block assigned to this deployment. Every VPC and the Cloud WAN GRE range must fall inside it.
#   10.103.0.0/24    VPC Palo Alto (security)     - AZ a: 10.103.0.0/25   | AZ b (reserved): 10.103.0.128/25
#   10.103.1.0/24    VPC Netskope SD-WAN          - primary: 10.103.1.0/25 | rest of the /24 free (single appliance, no HA)
#   10.103.255.0/24  Cloud WAN inside CIDR (GRE endpoints of the core network)
#   10.103.2.0/23 ... 10.103.254.0/24  free for growth (second region, more VPCs)
address_space = "10.103.0.0/16"
name_prefix   = "heico-" # TODO: update here

global_tags = {
  ManagedBy   = "terraform"
  Application = "Palo Alto VM-Series + Netskope SD-WAN + AWS Cloud WAN"
  Owner       = "Network Team" # TODO: update here
}

ssh_key_name = "lab-heico" # existing EC2 key pair in `region`

###############################################################################
# AWS CLOUD WAN
###############################################################################
cloudwan = {
  global_network_description = "HEICO global network"
  core_network_description   = "HEICO core network"

  # GRE (Connect) endpoints on the Cloud WAN side. Must not overlap any VPC / on-prem range.
  inside_cidr_blocks = ["10.103.255.0/24"] # TODO: update here

  # asn_ranges     = ["64520-64525"]
  # edge_locations = [{ location = "us-east-1", asn = 64520 }, { location = "ap-south-2", asn = 64521 }]

  segments = {
    workloads = {} # spoke VPCs (DR, Lucix, IndiaSub, ...)
    sdwan     = {} # Netskope SD-WAN gateway
  }

  network_function_group_name = "paloalto"

  # SD-WAN <-> workloads traffic is inspected by the firewall
  east_west_inspection = { sdwan = ["workloads"] }
  # Internet egress of both segments goes through the firewall (egress NAT on the VM-Series)
  internet_egress_segments = ["workloads", "sdwan"]
}

# The firewall VPC joins the network function group (service insertion). Spoke VPCs managed by this stack,
# if any, would be added here with `segment = "workloads"`.
cloudwan_attachments = {
  security = {
    name                   = "security-vpc"
    vpc                    = "security_vpc"
    subnet_group           = "cloudwan_attach"
    network_function_group = true
    appliance_mode_support = true
  }
}

###############################################################################
# PALO ALTO - SECURITY VPC (combined design, one VM-Series, one AZ)
# AZ a uses the first /25 of the VPC; the second /25 (10.103.0.128/25) is reserved for AZ b:
# duplicate every subnet there (same offsets +128) and add instance "02" below.
###############################################################################
vpcs = {
  security_vpc = {
    name = "security-vpc"
    cidr = "10.103.0.0/24"

    nacls = {
      trusted_path_monitoring = {
        name = "trusted-path-monitoring"
        rules = {
          block_outbound_icmp_1 = {
            rule_number = 110
            egress      = true
            protocol    = "icmp"
            rule_action = "deny"
            cidr_block  = "10.103.0.16/28"
          }
          allow_other_outbound = {
            rule_number = 200
            egress      = true
            protocol    = "-1"
            rule_action = "allow"
            cidr_block  = "0.0.0.0/0"
          }
          allow_inbound = {
            rule_number = 300
            egress      = false
            protocol    = "-1"
            rule_action = "allow"
            cidr_block  = "0.0.0.0/0"
          }
        }
      }
    }

    security_groups = {
      vmseries_private = {
        name = "vmseries_private"
        rules = {
          all_outbound = {
            description = "Permit All traffic outbound"
            type        = "egress", from_port = "0", to_port = "0", protocol = "-1"
            cidr_blocks = ["0.0.0.0/0"]
          }
          geneve = {
            description = "Permit GENEVE to GWLB subnets"
            type        = "ingress", from_port = "6081", to_port = "6081", protocol = "udp"
            cidr_blocks = ["10.103.0.80/28"]
          }
          health_probe = {
            description = "Permit Port 80 Health Probe to GWLB subnets"
            type        = "ingress", from_port = "80", to_port = "80", protocol = "tcp"
            cidr_blocks = ["10.103.0.80/28"]
          }
        }
      }
      vmseries_mgmt = {
        name = "vmseries_mgmt"
        rules = {
          all_outbound = {
            description = "Permit All traffic outbound"
            type        = "egress", from_port = "0", to_port = "0", protocol = "-1"
            cidr_blocks = ["0.0.0.0/0"]
          }
          # Direct firewall management access (admin range)
          https = {
            description = "Permit HTTPS"
            type        = "ingress", from_port = "443", to_port = "443", protocol = "tcp"
            cidr_blocks = ["186.154.161.143/32"] # admin IP
          }
          ssh = {
            description = "Permit SSH"
            type        = "ingress", from_port = "22", to_port = "22", protocol = "tcp"
            cidr_blocks = ["186.154.161.143/32"] # admin IP
          }
          panorama_ssh = {
            description = "Permit Panorama / internal management"
            type        = "ingress", from_port = "22", to_port = "22", protocol = "tcp"
            cidr_blocks = ["10.0.0.0/8"]
          }
        }
      }
      vmseries_public = {
        name = "vmseries_public"
        rules = {
          # Egress NAT interface: only outbound (return traffic is stateful). No inbound rules.
          all_outbound = {
            description = "Permit All traffic outbound"
            type        = "egress", from_port = "0", to_port = "0", protocol = "-1"
            cidr_blocks = ["0.0.0.0/0"]
          }
        }
      }
    }

    subnets = {
      # Value of `nacl` must match key of objects stored in `nacls`
      "10.103.0.0/28"  = { az = "us-east-1a", subnet_group = "mgmt" }
      "10.103.0.16/28" = { az = "us-east-1a", subnet_group = "private", nacl = "trusted_path_monitoring" }
      "10.103.0.32/28" = { az = "us-east-1a", subnet_group = "public" }
      "10.103.0.48/28" = { az = "us-east-1a", subnet_group = "cloudwan_attach" }
      "10.103.0.64/28" = { az = "us-east-1a", subnet_group = "gwlbe_outbound" }
      "10.103.0.80/28" = { az = "us-east-1a", subnet_group = "gwlb" }
      "10.103.0.96/28" = { az = "us-east-1a", subnet_group = "gwlbe_eastwest" }
    }

    routes = {
      # `next_hop_type`: internet_gateway | gwlbe_endpoint | core_network_attachment
      # `next_hop_key`: key of the VPC (IGW), of `gwlb_endpoints` or of `cloudwan_attachments`

      mgmt_default = {
        vpc           = "security_vpc"
        subnet_group  = "mgmt"
        to_cidr       = "0.0.0.0/0"
        next_hop_key  = "security_vpc"
        next_hop_type = "internet_gateway"
      }
      mgmt_rfc1918_10 = {
        vpc           = "security_vpc"
        subnet_group  = "mgmt"
        to_cidr       = "10.0.0.0/8"
        next_hop_key  = "security"
        next_hop_type = "core_network_attachment"
      }
      mgmt_rfc1918_172 = {
        vpc           = "security_vpc"
        subnet_group  = "mgmt"
        to_cidr       = "172.16.0.0/12"
        next_hop_key  = "security"
        next_hop_type = "core_network_attachment"
      }
      mgmt_rfc1918_192 = {
        vpc           = "security_vpc"
        subnet_group  = "mgmt"
        to_cidr       = "192.168.0.0/16"
        next_hop_key  = "security"
        next_hop_type = "core_network_attachment"
      }

      # Traffic arriving from Cloud WAN: private ranges (east-west) and default (internet egress) go to the firewall
      cloudwan_attach_rfc1918_10 = {
        vpc           = "security_vpc"
        subnet_group  = "cloudwan_attach"
        to_cidr       = "10.0.0.0/8"
        next_hop_key  = "security_gwlb_eastwest"
        next_hop_type = "gwlbe_endpoint"
      }
      cloudwan_attach_rfc1918_172 = {
        vpc           = "security_vpc"
        subnet_group  = "cloudwan_attach"
        to_cidr       = "172.16.0.0/12"
        next_hop_key  = "security_gwlb_eastwest"
        next_hop_type = "gwlbe_endpoint"
      }
      cloudwan_attach_rfc1918_192 = {
        vpc           = "security_vpc"
        subnet_group  = "cloudwan_attach"
        to_cidr       = "192.168.0.0/16"
        next_hop_key  = "security_gwlb_eastwest"
        next_hop_type = "gwlbe_endpoint"
      }
      cloudwan_attach_default = {
        vpc           = "security_vpc"
        subnet_group  = "cloudwan_attach"
        to_cidr       = "0.0.0.0/0"
        next_hop_key  = "security_gwlb_outbound"
        next_hop_type = "gwlbe_endpoint"
      }

      # Firewall egress NAT -> internet
      public_default = {
        vpc           = "security_vpc"
        subnet_group  = "public"
        to_cidr       = "0.0.0.0/0"
        next_hop_key  = "security_vpc"
        next_hop_type = "internet_gateway"
      }

      # Inspected traffic returns to Cloud WAN
      gwlbe_outbound_rfc1918_10 = {
        vpc           = "security_vpc"
        subnet_group  = "gwlbe_outbound"
        to_cidr       = "10.0.0.0/8"
        next_hop_key  = "security"
        next_hop_type = "core_network_attachment"
      }
      gwlbe_outbound_rfc1918_172 = {
        vpc           = "security_vpc"
        subnet_group  = "gwlbe_outbound"
        to_cidr       = "172.16.0.0/12"
        next_hop_key  = "security"
        next_hop_type = "core_network_attachment"
      }
      gwlbe_outbound_rfc1918_192 = {
        vpc           = "security_vpc"
        subnet_group  = "gwlbe_outbound"
        to_cidr       = "192.168.0.0/16"
        next_hop_key  = "security"
        next_hop_type = "core_network_attachment"
      }
      gwlbe_eastwest_rfc1918_10 = {
        vpc           = "security_vpc"
        subnet_group  = "gwlbe_eastwest"
        to_cidr       = "10.0.0.0/8"
        next_hop_key  = "security"
        next_hop_type = "core_network_attachment"
      }
      gwlbe_eastwest_rfc1918_172 = {
        vpc           = "security_vpc"
        subnet_group  = "gwlbe_eastwest"
        to_cidr       = "172.16.0.0/12"
        next_hop_key  = "security"
        next_hop_type = "core_network_attachment"
      }
      gwlbe_eastwest_rfc1918_192 = {
        vpc           = "security_vpc"
        subnet_group  = "gwlbe_eastwest"
        to_cidr       = "192.168.0.0/16"
        next_hop_key  = "security"
        next_hop_type = "core_network_attachment"
      }
    }
  }
}

### GATEWAY LOAD BALANCER
gwlbs = {
  security_gwlb = {
    name         = "security-gwlb"
    vpc          = "security_vpc"
    subnet_group = "gwlb"
  }
}

gwlb_endpoints = {
  security_gwlb_eastwest = {
    name            = "eastwest-gwlb-endpoint"
    gwlb            = "security_gwlb"
    vpc             = "security_vpc"
    subnet_group    = "gwlbe_eastwest"
    act_as_next_hop = false
  }
  security_gwlb_outbound = {
    name            = "outbound-gwlb-endpoint"
    gwlb            = "security_gwlb"
    vpc             = "security_vpc"
    subnet_group    = "gwlbe_outbound"
    act_as_next_hop = false
  }
  # Combined model: for inbound traffic add one endpoint per spoke VPC managed by this stack
  # (act_as_next_hop = true, from_igw_to_vpc / from_igw_to_subnet_group) and reference it in
  # `vmseries.<group>.subinterfaces.inbound`. See examples/combined_design of the PAN repository.
}

### VM-SERIES (one firewall, no autoscaling)
vmseries = {
  vmseries = {
    instances = {
      "01" = { az = "us-east-1a" }
    }

    # SCM (Strata Cloud Manager) bootstrap, PAN-OS 11.0 or higher.
    # LAB ONLY: the PIN value is stored here. In the customer environment use `bootstrap_secrets` (sensitive variable).
    bootstrap_options = {
      mgmt-interface-swap         = "enable"
      panorama-server             = "cloud"
      dgname                      = "heico-cloudwan-lab" # SCM folder
      plugin-op-commands          = "aws-gwlb-inspect:enable,aws-gwlb-overlay-routing:enable,advance-routing:enable"
      dhcp-send-hostname          = "yes"
      dhcp-send-client-id         = "yes"
      dhcp-accept-server-hostname = "yes"
      dhcp-accept-server-domain   = "yes"
      vm-series-auto-registration-pin-id    = "f7aa0dd0-194c-4122-aaa8-f11a8efbe32a" # SCM registration PIN ID
      vm-series-auto-registration-pin-value = "3a202f8cc6394d9bb81f45f214c4d026"         # LAB ONLY (secret)
    }

    panos_version = "11.2.8"        # TODO: update here
    ebs_kms_id    = "alias/aws/ebs" # TODO: update here

    vpc  = "security_vpc"
    gwlb = "security_gwlb"

    interfaces = {
      private = {
        device_index      = 0
        security_group    = "vmseries_private"
        subnet_group      = "private"
        create_public_ip  = false
        source_dest_check = false
      }
      mgmt = {
        device_index      = 1
        security_group    = "vmseries_mgmt"
        subnet_group      = "mgmt"
        create_public_ip  = true
        source_dest_check = true
      }
      public = {
        device_index      = 2
        security_group    = "vmseries_public"
        subnet_group      = "public"
        create_public_ip  = true
        source_dest_check = false
      }
    }

    subinterfaces = {
      inbound = {}
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
      ntp_primary = "pool.ntp.org" # TODO: update here
    }
  }
}

###############################################################################
# NETSKOPE SD-WAN GATEWAY - own VPC (10.103.1.0/24), separate from the security VPC
# Secrets: `netskope_gateway_password` (and `netskope_api_token` only with portal_automation = true) -> secrets.auto.tfvars
###############################################################################
netskope = {
  enabled = true

  # false = infrastructure only (flow of the greenfield template downloaded from the Netskope console):
  #         activate and configure the gateway from the console. The GRE / BGP values to enter there are
  #         printed in the output `netskope_cloudwan_connect_details`.
  # true  = legacy API flow: Terraform also configures policy / gateway / interfaces / BGP in the portal
  #         (needs tenant.tenant_id, tenant.tenant_url and `netskope_api_token`).
  portal_automation = false

  tenant = {
    tenant_bgp_asn = "400" # BGP ASN of the gateway (used by the Cloud WAN Connect peer)
    # Customer tenant. Only used with portal_automation = true (ignored in console mode):
    tenant_id  = "heicocorp"
    tenant_url = "https://heicocorp.infiot.net" # portal URL; a trailing path such as /bwan/ is ignored
  }

  vpc = {
    name = "sdwan-vpc"
    cidr = "10.103.1.0/24"

    # ge1 = WAN (public, EIP); ge2 = LAN (Cloud WAN attachment + GRE tunnel). `private_ip` is optional (fixed IP).
    primary_gw_subnets = {
      ge1 = { subnet_cidr = "10.103.1.0/28", private_ip = "10.103.1.8" }
      ge2 = { subnet_cidr = "10.103.1.16/28", private_ip = "10.103.1.24" }
    }
  }

  cloudwan = {
    segment = "sdwan"
    # primary_inside_cidr = "169.254.100.0/29" # BGP inside CIDR of the GRE peer
  }

  gateway = {
    ha_enabled = false # single appliance, no HA
    # Only used with portal_automation = true:
    # gateway_name   = "aws-use1-sdwan-gw"
    # gateway_policy = "aws-use1-sdwan-gw"
    # gateway_role   = "hub"
  }

  instance = {
    ami_id = "ami-07bb168bd669677aa" # Netskope unified SASE virtual gateway (us-east-1)
    # instance_type    = "c5.xlarge"
    # root_volume_size = 80 # default: size of the AMI snapshot (this AMI needs >= 80 GB)
    # root_volume_type = "gp3"
  }

  ssh_allowed_cidrs   = ["186.154.161.143/32"] # admin IP
  https_allowed_cidrs = ["186.154.161.143/32"] # admin IP
  ssh_password_auth   = false # true enables SSH password login (needs netskope_gateway_password)
}
