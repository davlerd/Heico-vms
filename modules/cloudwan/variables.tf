# Slim copy of aws-ia/terraform-aws-cloudwan (Apache-2.0, see LICENSE / NOTICE.txt).
# Kept: global network, core network, core network policy attachment and RAM share.
# Removed (not used by this stack): central VPCs and AWS Network Firewall (they pulled the external
# aws-ia/vpc, aws-ia/networkfirewall and aws-ia/label modules at `terraform init`).

# ---------- GLOBAL NETWORK ---------
variable "global_network_id" {
  type        = string
  description = "(Optional) Global Network ID. Conflicts with `var.global_network`."
  default     = null

  validation {
    condition     = var.global_network_id == null || can(regex("^global-network-[0-9a-f]{8,17}$", var.global_network_id))
    error_message = "var.global_network_id must match global-network- followed by 8 to 17 lowercase hexadecimal characters."
  }
}

variable "global_network" {
  description = <<-EOF
    Global Network definition - providing information to this variable will create a new Global Network. Conflicts with `var.global_network_id`.
    This variable expects the following attributes:
    - `description` = (string) Global Network's description.
    - `tags`        = (Optional|map(string)) Tags to apply to the Global Network.
EOF
  type        = any
  default     = {}

  validation {
    condition = var.global_network == null ? true : try(length(setsubtract(keys(var.global_network), [
      "description",
      "tags"
    ])) == 0, false)
    error_message = "Only valid key values for var.global_network are \"description\" and \"tags\"."
  }

  validation {
    condition = var.global_network == null || try(length(keys(var.global_network)) == 0, false) ? true : try(
      contains(keys(var.global_network), "description") &&
      var.global_network.description == tostring(var.global_network.description) &&
      (!contains(keys(var.global_network), "tags") || var.global_network.tags == null || alltrue([
        for value in values(var.global_network.tags) : value == tostring(value)
      ])),
      false
    )
    error_message = "A non-empty var.global_network must include string description; optional tags must be a map of strings."
  }
}

# ---------- CORE NETWORK ----------
variable "core_network_arn" {
  type        = string
  description = "(Optional) Core Network ARN. Conflicts with `var.core_network`."
  default     = null

  validation {
    condition     = var.core_network_arn == null || can(regex("^arn:[^:]+:networkmanager::[0-9]{12}:core-network/core-network-[0-9a-f]{8,17}$", var.core_network_arn))
    error_message = "var.core_network_arn must be a complete Network Manager Core Network ARN: arn:<partition>:networkmanager::<12-digit-account>:core-network/core-network-<8-to-17-hex>."
  }
}

variable "core_network" {
  description = <<-EOF
    Core Network definition - providing information to this variable will create a new Core Network. Conflicts with `var.core_network_arn`.
    This variable expects the following attributes:
    - `description`                              = (string) Core Network's description.
    - `policy_document`                          = (string) Core Network's policy in JSON format.
    - `base_policy_document`                     = (Optional|string) Explicit create-only base policy JSON. Conflicts with `base_policy_regions`.
    - `base_policy_regions`                      = (Optional|collection(string)) Create-only Regions used to generate the base policy. Conflicts with `base_policy_document`.
    - `resource_share_name`                      = (Optional|string) AWS Resource Access Manager (RAM) Resource Share name. Providing this value, RAM resources will be created to share the Core Network with the principals indicated in `var.core_network.ram_share_principals`.
    - `resource_share_allow_external_principals` = (Optional|bool) Indicates whether principals outside your AWS Organization can be associated with a Resource Share.
    - `ram_share_principals`                     = (Optional|list(string)) List of principals (AWS Account or AWS Organization) to share the Core Network with.
    - `tags`                                     = (Optional|map(string)) Tags to apply to the Core Network and RAM Resource Share (if created).
EOF
  type        = any
  default     = {}

  validation {
    condition = var.core_network == null ? true : try(length(setsubtract(keys(var.core_network), [
      "description",
      "policy_document",
      "base_policy_document",
      "base_policy_regions",
      "resource_share_name",
      "resource_share_allow_external_principals",
      "ram_share_principals",
      "tags"
    ])) == 0, false)
    error_message = "Only valid key values for var.core_network are \"description\", \"policy_document\", \"base_policy_document\", \"base_policy_regions\", \"resource_share_name\", \"resource_share_allow_external_principals\", \"ram_share_principals\", and \"tags\"."
  }

  validation {
    condition = var.core_network == null || try(length(keys(var.core_network)) == 0, false) ? true : try(
      contains(keys(var.core_network), "description") &&
      var.core_network.description == tostring(var.core_network.description) &&
      contains(keys(var.core_network), "policy_document") &&
      var.core_network.policy_document == tostring(var.core_network.policy_document) &&
      (!contains(keys(var.core_network), "base_policy_document") || var.core_network.base_policy_document == null || var.core_network.base_policy_document == tostring(var.core_network.base_policy_document)) &&
      (!contains(keys(var.core_network), "base_policy_regions") || var.core_network.base_policy_regions == null || (
        length(var.core_network.base_policy_regions) > 0 && alltrue([
          for region in var.core_network.base_policy_regions : region == tostring(region)
        ])
      )) &&
      !(try(var.core_network.base_policy_document, null) != null && try(var.core_network.base_policy_regions, null) != null) &&
      (!contains(keys(var.core_network), "resource_share_name") || var.core_network.resource_share_name == null || var.core_network.resource_share_name == tostring(var.core_network.resource_share_name)) &&
      (!contains(keys(var.core_network), "resource_share_allow_external_principals") || var.core_network.resource_share_allow_external_principals == null || var.core_network.resource_share_allow_external_principals == tobool(var.core_network.resource_share_allow_external_principals)) &&
      (!contains(keys(var.core_network), "ram_share_principals") || var.core_network.ram_share_principals == null || alltrue([
        for principal in var.core_network.ram_share_principals : principal == tostring(principal)
      ])) &&
      (!contains(keys(var.core_network), "tags") || var.core_network.tags == null || alltrue([
        for value in values(var.core_network.tags) : value == tostring(value)
      ])),
      false
    )
    error_message = "A non-empty var.core_network must include string description and policy_document. Optional share fields and tags must use their documented types; base_policy_document and base_policy_regions are mutually exclusive."
  }

  validation {
    condition = var.core_network == null || try(length(keys(var.core_network)) == 0, false) ? true : try(
      can(jsondecode(var.core_network.policy_document)) &&
      contains(keys(jsondecode(var.core_network.policy_document)), "version") &&
      jsondecode(var.core_network.policy_document).version == tostring(jsondecode(var.core_network.policy_document).version) &&
      contains(keys(jsondecode(var.core_network.policy_document)), "core-network-configuration") &&
      can(keys(jsondecode(var.core_network.policy_document)["core-network-configuration"])) &&
      contains(keys(jsondecode(var.core_network.policy_document)), "segments") &&
      can(tolist(jsondecode(var.core_network.policy_document).segments)),
      false
    )
    error_message = "var.core_network.policy_document must be valid JSON with string version, object core-network-configuration, and segments as a JSON list."
  }
}

# ---------- TAGS ----------
variable "tags" {
  description = "(Optional) Tags to apply to all resources."
  type        = map(string)
  default     = {}
}
