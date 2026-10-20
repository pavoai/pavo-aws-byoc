# =============================================================================
# Cell -> instance readiness gates (the SSM "API")
# =============================================================================
# pavo-bootstrap-aws (cell-scoped, applied by the customer) publishes one SSM
# parameter per capability it installed. An instance that depends on a capability
# reads this listing and fails fast, with an actionable message, when the cell was
# never bootstrapped for it.
#
# A TOLERANT lookup on purpose. The obvious form, data.aws_ssm_parameter on the
# exact name, errors during the READ when the parameter is absent, so the plan
# dies with a bare "couldn't find resource" that never names the flag the operator
# has to flip and leaves them nothing to act on. That is what a real onboarding
# hit. Reading the path instead returns an empty list rather than erroring, which
# lets each consumer's precondition produce a message that names the fix.
#
# with_decryption = false: we only need to know a NAME exists, and decrypted
# SecureString values returned by this data source land in plain Terraform state.
# recursive = false keeps the read to the cell's direct children.
#
# Read on EVERY instance (count = 1). It used to be the union of the readiness
# gates below, all derived from instance parameters, but the connector values at
# the bottom of this file render IAM and the strict egress policy and must not
# depend on instance parameters: an early phase of every deploy renders without
# them (0b5f9db: a grant gated on instance parameters was revoked for 79 and 28
# minutes that way). The read is covered by the shared SSMRead statement on
# /pavo/* in pavo-bootstrap-aws/policy-statements.json, the same grant
# data.aws_ssm_parameter.permission_boundary_arn already needs on every
# instance. A path with no parameters returns an empty listing, not an error.
# Add new gates here rather than adding a second listing elsewhere.
data "aws_ssm_parameters_by_path" "cell" {
  count           = 1
  path            = "/pavo/cells/${var.eks_cluster_name}"
  recursive       = false
  with_decryption = false
}

locals {
  # try() is load-bearing on every *_present local below, do NOT rewrite any of
  # them as `local.<gate>_count == 1 && contains(...)`. Terraform's && does NOT
  # short-circuit, so on an instance that does not use the gate the [0] index is
  # still evaluated against an empty tuple and the plan fails with "the collection
  # has no elements" for EVERY such instance. Verified against a live cell.
  cell_param_names = try(data.aws_ssm_parameters_by_path.cell[0].names, [])

  eck_ready_name            = "/pavo/cells/${var.eks_cluster_name}/eck_ready"
  observability_ready_name  = "/pavo/cells/${var.eks_cluster_name}/observability_ready"
  private_ca_ready_name     = "/pavo/cells/${var.eks_cluster_name}/private_ca_ready"
  network_policy_ready_name = "/pavo/cells/${var.eks_cluster_name}/network_policy_ready"

  eck_ready_present            = contains(local.cell_param_names, local.eck_ready_name)
  observability_ready_present  = contains(local.cell_param_names, local.observability_ready_name)
  private_ca_ready_present     = contains(local.cell_param_names, local.private_ca_ready_name)
  network_policy_ready_present = contains(local.cell_param_names, local.network_policy_ready_name)
}

# Connector values (cell -> instance). Unlike the readiness markers above these
# carry VALUES: pavo-bootstrap-aws publishes them as JSON in String parameters
# from customer-supplied inputs (connector_assumable_role_arns,
# strict_egress_extra_destinations). Absent parameter = nothing extra.
#
# The provider always marks `values` sensitive (the listing could hold
# SecureString ciphertext). These two are non-secret ARNs and CIDRs, and they
# have to be readable in the rendered IAM policy and NetworkPolicy, so they are
# unmarked. try(nonsensitive(x), x) rather than nonsensitive(x): the fallback
# "[]" is not sensitive and nonsensitive() rejects an unmarked value. A
# malformed value fails jsondecode loudly instead of silently granting nothing.
locals {
  _cell_param_values = try(zipmap(
    data.aws_ssm_parameters_by_path.cell[0].names,
    data.aws_ssm_parameters_by_path.cell[0].values,
  ), {})

  connector_assumable_role_arns_name    = "/pavo/cells/${var.eks_cluster_name}/connector_assumable_role_arns"
  strict_egress_extra_destinations_name = "/pavo/cells/${var.eks_cluster_name}/strict_egress_extra_destinations"

  _connector_assumable_role_arns_json    = try(local._cell_param_values[local.connector_assumable_role_arns_name], "[]")
  _strict_egress_extra_destinations_json = try(local._cell_param_values[local.strict_egress_extra_destinations_name], "[]")

  connector_assumable_role_arns = jsondecode(try(
    nonsensitive(local._connector_assumable_role_arns_json),
    local._connector_assumable_role_arns_json,
  ))
  strict_egress_extra_destinations = jsondecode(try(
    nonsensitive(local._strict_egress_extra_destinations_json),
    local._strict_egress_extra_destinations_json,
  ))
}
