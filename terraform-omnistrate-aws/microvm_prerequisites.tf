# Bootstrap is customer-applied on a different release clock from pavoInfra.
# A missing parameter must produce our remediation, not a provider read error.
# Disabled instances make no lookup; never decrypt unrelated shared parameters.
data "aws_ssm_parameters_by_path" "microvm_prerequisites" {
  count           = local.microvm_count
  path            = "/pavo/shared"
  recursive       = false
  with_decryption = false
}

locals {
  microvm_shared_parameters = zipmap(
    try(data.aws_ssm_parameters_by_path.microvm_prerequisites[0].names, []),
    try(data.aws_ssm_parameters_by_path.microvm_prerequisites[0].values, []),
  )
  microvm_publisher_boundary_arn = lookup(local.microvm_shared_parameters, "/pavo/shared/microvm_publisher_boundary_arn", "")
  microvm_build_boundary_arn     = lookup(local.microvm_shared_parameters, "/pavo/shared/microvm_build_boundary_arn", "")
}

resource "terraform_data" "microvm_prerequisites" {
  count = local.microvm_count
  input = {
    publisher_boundary = local.microvm_publisher_boundary_arn
    build_boundary     = local.microvm_build_boundary_arn
  }
  lifecycle {
    precondition {
      condition = (
        local.microvm_publisher_boundary_arn == "arn:aws:iam::${data.aws_caller_identity.current.account_id}:policy/pavo-permission-boundary-microvm-publisher" &&
        local.microvm_build_boundary_arn == "arn:aws:iam::${data.aws_caller_identity.current.account_id}:policy/pavo-permission-boundary-microvm-build"
      )
      error_message = "Managed MicroVM image prerequisites are missing or invalid in this AWS account/region. The customer AWS owner must update the existing pavo-bootstrap-aws root to a bootstrap-v* release containing MicroVM support, set enable_microvm_image_builds = true, and apply it through the existing bootstrap state. Verify /pavo/shared/microvm_publisher_boundary_arn and /pavo/shared/microvm_build_boundary_arn, then retry this instance. No managed release configuration or publisher resources will be provisioned before this gate succeeds."
    }
  }
}
