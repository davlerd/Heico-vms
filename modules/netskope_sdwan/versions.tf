# Ported from https://github.com/netskopeoss/terraform-netskopebwan-aws (Copyright (c) 2022 Infiot / Netskope).
# Changes: Transit Gateway + TGW Connect replaced by AWS Cloud WAN (VPC attachment + Connect attachment),
# the three original modules (aws_vpc / nsg_config / aws_ec2) merged in one, AWS provider >= 6 compatible
# (aws_eip `domain`), existing-VPC mode and the demo client removed.
terraform {
  required_version = ">= 1.9.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0.0"
    }
    time = {
      source  = "hashicorp/time"
      version = ">= 0.11.1"
    }
    netskopebwan = {
      source  = "netskopeoss/netskopebwan"
      version = "0.0.2"
    }
  }
}
