# =============================================================================
# Strict-cell egress NetworkPolicies (network_posture = strict)
# =============================================================================
# A default-deny egress posture for the instance's workload namespace: pods may
# reach only in-VPC / endpoint destinations (RDS, Redis, EFS, the VPC interface
# endpoints, S3 via the gateway endpoint, the Kubernetes API). Everything else —
# the public internet, and the IMDS link-local 169.254.169.254 (not in any
# allowed range) — is denied.
#
# Scope: this governs PODS IN THE STRICT INSTANCE'S WORKLOAD NAMESPACE
# (var.instance_id). Platform/control-plane namespaces (kube-system, cert-manager,
# external-secrets, cosign-system, elastic-system, pavo-observability) are NOT
# governed here — they carry their own policies or are control-plane exceptions.
# So "default-deny egress" here means namespace-scoped, NOT cell-wide; say it that
# way to customers. A cell-wide posture additionally needs the cosign admission
# path off public Sigstore (an offline-verification design, not yet built) and an egress path for
# the alert forwarder, neither of which is in this change.
# Ingress isolation is deliberately out of scope (this is external-egress default
# deny / a VPC-contained posture, not east-west microsegmentation).
#
# Lifecycle: mirrors kubectl_manifest.es_network_policy — per-instance, count-
# gated, SSA, depends_on the namespace, and deliberately NOT apply_only, so a
# strict -> standard flip DELETES the policy (an orphaned default-deny would keep
# denying egress after rollback = outage).
#
# Enforcement: inert until the cell's CNI NetworkPolicy enforcement is on
# (network_policy_ready, gated below). The AWS-managed SGs egress 0.0.0.0/0, so
# this NetworkPolicy is the primary egress control, not a mirror of an SG.

locals {
  strict_count = var.network_posture == "strict" ? 1 : 0

  # Allowed egress destination CIDRs for a strict pod:
  #   - every VPC CIDR (primary + secondary) — covers RDS/Redis/EFS + the VPC
  #     interface endpoints (they get private-subnet IPs in these). Under the AWS
  #     VPC CNI, pod IPs come from these same subnets, so this also covers all
  #     pod-to-pod traffic (CoreDNS included) without a separate rule.
  #   - the AWS-managed S3 prefix-list ranges — S3 rides the cell's S3 GATEWAY
  #     endpoint (pavo-bootstrap-aws), whose destination is the S3 service range,
  #     NOT the VPC CIDR. (DynamoDB intentionally omitted — no Pavo pod uses it;
  #     add only if the dependency inventory changes.)
  #   - the Kubernetes service CIDR — ClusterIP/API can be outside the VPC CIDR.
  #
  # Splat rather than `local.strict_count == 0 ? [] : ... s3[0].cidr_blocks`. Both
  # work — the conditional does short-circuit for a count-gated data source
  # (checked on Terraform 1.16 and OpenTofu 1.12), unlike `&&`, which is the trap
  # cell_gates.tf documents. Splat is preferred here only because it needs no
  # guard at all: the empty tuple flattens to [], so there is no [0] to get wrong
  # if someone later edits the gate.
  strict_egress_cidrs = concat(
    data.aws_vpc.eks.cidr_block_associations[*].cidr_block,
    flatten(data.aws_prefix_list.s3[*].cidr_blocks),
    data.aws_eks_cluster.primary.kubernetes_network_config[*].service_ipv4_cidr,
  )
}

# S3-gateway destination ranges for the egress allowlist (strict only). Reads the
# AWS-managed S3 prefix list (the same one the S3 gateway endpoint routes to) via
# ec2:DescribePrefixLists.
#
# The principal that matters here is the TERRAFORM RUNNER, not the workload role:
# a `data` source is read with the AWS provider's credentials, so a grant on the
# Kubernetes workload role would not help. It is granted, via the
# `ReadOnlyDescribeList` statement in pavo-bootstrap-aws/policy-statements.json,
# which carries no `scope` — and absent scope means SHARED, i.e. both the workload
# boundary and the runner policy (spec CUSTOM_TERRAFORM_POLICY, kept in sync by
# sync-policy-to-spec.py). So strict needs no new IAM.
#
# If that statement is ever narrowed to scope="boundary", this data source loses
# its permission and EVERY strict plan fails before the policy is created.
data "aws_prefix_list" "s3" {
  count = local.strict_count
  filter {
    name   = "prefix-list-name"
    values = ["com.amazonaws.${var.aws_region}.s3"]
  }
}

# Default-deny egress + allowlist for the instance workload namespace. A single
# all-pods Egress policy with an explicit allow set == default-deny-except-allowed.
resource "kubectl_manifest" "strict_egress" {
  count = local.strict_count

  # Fail-fast on the two cell capabilities a strict instance cannot work without,
  # each naming the pavo-bootstrap-aws flag the operator has to flip. Same shape
  # as the eck_ready precondition — the gate is the tolerant SSM listing in
  # cell_gates.tf, so an unbootstrapped cell produces these messages rather than a
  # bare "couldn't find resource" from a failed parameter read.
  #
  # These also fire on an ALREADY-CREATED strict instance whose cell later drops
  # either capability, which is the intended true->false hazard signal.
  lifecycle {
    precondition {
      condition     = local.private_ca_ready_present
      error_message = <<-EOT
        network_posture = "strict" requires the in-cell private CA on cell
        ${var.eks_cluster_name}, but ${local.private_ca_ready_name} does not exist.

        FIX: re-run pavo-bootstrap-aws for this cell with install_private_ca = true,
        then retry this deployment. The cell publishes that parameter only after the
        pavo-private-ca ClusterIssuer is actually Ready.
      EOT
    }
    precondition {
      condition     = local.network_policy_ready_present
      error_message = <<-EOT
        network_posture = "strict" requires AWS VPC CNI NetworkPolicy ENFORCEMENT on
        cell ${var.eks_cluster_name}, but ${local.network_policy_ready_name} does not
        exist. Without enforcement this default-deny policy is inert and the instance
        would silently still egress to the internet.

        FIX: confirm with Omnistrate that the cell's vpc-cni add-on has
        NETWORK_POLICY_ENFORCING_MODE=standard, then re-run pavo-bootstrap-aws for
        this cell with network_policy_ready = true.
      EOT
    }
  }

  yaml_body = yamlencode({
    apiVersion = "networking.k8s.io/v1"
    kind       = "NetworkPolicy"
    metadata = {
      name      = "pavo-strict-egress"
      namespace = var.instance_id
    }
    spec = {
      podSelector = {}
      policyTypes = ["Egress"]
      egress = [
        # In-VPC + S3-gateway + Kubernetes service ranges (all ports). Under the
        # VPC CNI this also covers DNS and same-namespace pod-to-pod, since pod
        # IPs are VPC IPs — a separate kube-system/podSelector rule would be dead
        # weight. The one case it does NOT cover is a NodeLocal DNS cache, which
        # answers on a link-local address: the validation run reads /etc/resolv.conf in a
        # strict pod and, if a node-local resolver is in use, adds exactly that
        # /32 here (never a broad link-local exception, which would reopen IMDS
        # 169.254.169.254).
        { to = [for cidr in local.strict_egress_cidrs : { ipBlock = { cidr = cidr } }] },
      ]
    }
  })

  server_side_apply = true
  force_conflicts   = true
  depends_on        = [kubectl_manifest.instance_namespace]
}
