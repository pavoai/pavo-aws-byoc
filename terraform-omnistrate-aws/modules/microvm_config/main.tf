# Pure configuration resolution. Kept separate so omission/retry behavior can be
# exercised using real Terraform expressions without AWS credentials/resources.
terraform {
  required_version = ">= 1.5"
}

variable "account_id" { type = string }
variable "instance_id" { type = string }
variable "region" { type = string }
variable "requested_enabled" {
  type    = bool
  default = false
}
variable "publisher_image" {
  type    = string
  default = ""
}
variable "revision" {
  type    = string
  default = ""
}
variable "stored_config" {
  description = "Previously persisted non-secret release configuration, or empty when not enabled yet."
  type        = string
  default     = ""
}

locals {
  image_pattern    = "^ghcr\\.io/pavoai/microvm-publisher@sha256:[0-9a-f]{64}$"
  revision_pattern = "^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"
  stored_present   = var.stored_config != ""
  stored           = try(jsondecode(var.stored_config), {})
  stored_valid = try(
    local.stored.schema_version == 1 && local.stored.enabled == true &&
    local.stored.account_id == var.account_id &&
    local.stored.instance_id == var.instance_id &&
    local.stored.region == var.region &&
    can(regex(local.image_pattern, local.stored.publisher_image)) &&
    can(regex(local.revision_pattern, local.stored.revision)),
    false
  )
  complete_request = var.requested_enabled && can(regex(local.image_pattern, var.publisher_image)) && can(regex(local.revision_pattern, var.revision))
  # A complete explicit request may change a release. Partial/default inputs
  # may only match or omit the persisted values, never silently change them.
  compatible_omission = local.stored_valid && (
    var.publisher_image == "" || var.publisher_image == try(local.stored.publisher_image, "")
  ) && (var.revision == "" || var.revision == try(local.stored.revision, ""))
  enabled         = local.complete_request || local.stored_present
  publisher_image = local.complete_request ? var.publisher_image : try(local.stored.publisher_image, "")
  revision        = local.complete_request ? var.revision : try(local.stored.revision, "")
  manifest = local.enabled ? jsonencode({
    schema_version  = 1
    enabled         = true
    account_id      = var.account_id
    instance_id     = var.instance_id
    region          = var.region
    publisher_image = local.publisher_image
    revision        = local.revision
  }) : ""
}

resource "terraform_data" "validation" {
  # Only effective inputs belong here: losing transient API params must not
  # cause changes to the guard, Job or any downstream resource.
  input = local.manifest
  lifecycle {
    precondition {
      condition     = !local.stored_present || local.stored_valid
      error_message = "The persisted MicroVM release configuration is invalid or belongs to a different account, instance or region. Repair it through the owning deployment state."
    }
    precondition {
      condition = local.complete_request || local.compatible_omission || (
        !var.requested_enabled && var.publisher_image == "" && var.revision == ""
      )
      error_message = "Initial enable or release changes require enabled=true and a complete digest/revision pair. Omitted or matching inputs retain an existing release."
    }
  }
}

output "enabled" { value = local.enabled }
output "publisher_image" { value = local.publisher_image }
output "revision" { value = local.revision }
output "manifest" { value = local.manifest }
