# -----------------------------------------------------------------------------
# Edge certificate for strict cells (ACM public, DNS-validated)
# -----------------------------------------------------------------------------
# Strict cells sit behind an internal NLB, so cert-manager's HTTP-01 path to
# Let's Encrypt is gone. The NLB's TLS listener presents an Amazon Trust
# Services certificate (in mainstream OS/browser trust stores) that this module
# requests; the ingress leaves behind it are self-signed and never validated.
#
# Validation is split on purpose:
#   - here:      request only, emit the CNAMEs ACM wants, one per base name.
#                Pavo writes the <customer>.<base_domain> one in its zone; a
#                custom app_domain adds one in the customer's DNS, which Pavo
#                sends to the customer (any DNS provider, a plain CNAME).
#   - pavoInfra: aws_acm_certificate_validation waits for ISSUED (60 min), which
#                is the window Pavo has to write the CNAME. ingress-nginx takes
#                the ARN from pavoInfra, so it only ever sees an issued cert.
#
# A strict cell has no NAT: ACM is reachable only through the `acm` interface
# endpoint pavo-bootstrap-aws creates, and without it RequestCertificate hangs
# for the SDK's full retry budget. The gate below turns that into the same
# plan-time "run the bootstrap" failure pavoInfra gives, so a fresh cell fails
# fast and the retry after the bootstrap applies this in minutes.
# -----------------------------------------------------------------------------

locals {
  strict = var.network_posture == "strict"

  # Same derivation as terraform-omnistrate-aws (main.tf app_domain,
  # zitadel_self_hosted.tf zitadel_auth_host); kept in sync by hand because
  # Omnistrate ships no shared modules.
  derived    = "${var.customer_name}.${var.base_domain}"
  app_domain = var.app_domain != "" ? var.app_domain : local.derived
  auth_host  = var.auth_hostname != "" ? var.auth_hostname : "auth.${local.derived}"

  # One wildcard per base covers api./auth./kibana./temporal./grafana. (one label).
  wildcard_bases = distinct([local.app_domain, local.derived])
  auth_covered = anytrue([
    for b in local.wildcard_bases : can(regex("^[^.]+\\.${replace(b, ".", "\\.")}$", local.auth_host))
  ])

  san_candidates = concat(
    flatten([for b in local.wildcard_bases : [b, "*.${b}"]]),
    local.auth_covered ? [] : [local.auth_host],
  )
  sans = [for s in distinct(local.san_candidates) : s if s != local.app_domain]
}

# Bootstrap-applied gate, same listing terraform-omnistrate-aws/cell_gates.tf
# reads. vpc_id is published by every bootstrap apply; SSM itself is reachable
# before the bootstrap (Omnistrate creates that endpoint with the cell).
data "aws_ssm_parameters_by_path" "cell" {
  count           = local.strict ? 1 : 0
  path            = "/pavo/cells/${var.eks_cluster_name}"
  recursive       = false
  with_decryption = false
}

locals {
  bootstrap_applied = contains(
    try(data.aws_ssm_parameters_by_path.cell[0].names, []),
    "/pavo/cells/${var.eks_cluster_name}/vpc_id",
  )
}

resource "aws_acm_certificate" "edge" {
  count = local.strict ? 1 : 0

  domain_name               = local.app_domain
  subject_alternative_names = local.sans
  validation_method         = "DNS"

  lifecycle {
    # Hostname changes mint a new cert; the old one is deleted only after
    # ingress-nginx re-points the listener (next Omnistrate apply).
    create_before_destroy = true

    precondition {
      condition     = local.bootstrap_applied
      error_message = <<-EOT
        network_posture = "strict" requires pavo-bootstrap-aws on cell
        ${var.eks_cluster_name} (it creates the acm interface endpoint this
        request needs), but /pavo/cells/${var.eks_cluster_name}/vpc_id does
        not exist. Run the bootstrap, then retry this deployment.
      EOT
    }
  }
}

locals {
  validation_records = local.strict ? distinct([
    for o in aws_acm_certificate.edge[0].domain_validation_options : {
      name  = o.resource_record_name
      type  = o.resource_record_type
      value = o.resource_record_value
    }
  ]) : []
}
