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
# The count is the UNION of every gate below — an instance with
# grafana_mode = self_hosted but es_mode = cloud still needs the listing. Add new
# gates here rather than adding a second listing elsewhere.
data "aws_ssm_parameters_by_path" "cell" {
  count           = max(local.es_count, local.obs_gate_count, local.strict_count)
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
