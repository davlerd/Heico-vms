terraform {
  required_version = ">= 1.9.0, < 2.0.0"

  required_providers {
    # >= 6.0 is required by the Cloud WAN module (multi-region `region` argument on RAM resources).
    # The Netskope module was ported from ~> 4.30 (see modules/netskope_sdwan).
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0.0, < 7.0.0"
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
