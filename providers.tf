provider "aws" {
  region = var.region

  default_tags {
    tags = var.global_tags
  }
}

# The Netskope API endpoint is derived from the tenant URL, e.g.
#   https://example.infiot.net  ->  https://example.api.infiot.net
locals {
  netskope_tenant_url_slice = split(".", var.netskope.tenant.tenant_url)
  netskope_api_url = join(".", concat(
    slice(local.netskope_tenant_url_slice, 0, 1),
    ["api"],
    slice(local.netskope_tenant_url_slice, 1, length(local.netskope_tenant_url_slice))
  ))
}

provider "netskopebwan" {
  baseurl  = local.netskope_api_url
  apitoken = var.netskope_api_token
}
