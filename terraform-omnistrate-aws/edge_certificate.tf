# -----------------------------------------------------------------------------
# Edge certificate validation wait (strict posture)
# -----------------------------------------------------------------------------
# pavo-cert-aws (the pavoCert resource) REQUESTS the ACM certificate and emits
# the validation CNAME; Pavo writes that record in its DNS zone during this
# resource's wait. It blocks until ACM reports ISSUED and only then exports
# edge_certificate_arn, the ARN ingress-nginx puts on the NLB listener — so a
# PENDING certificate can never reach the LB controller, which rejects it and
# would burn the helm wait.
#
# Lives here, not in pavo-cert-aws, because the CNAME value exists only after
# the request apply; a wait in the same apply would fail with nothing to act on.
# -----------------------------------------------------------------------------

locals {
  edge_cert_count = var.network_posture == "strict" ? 1 : 0
}

resource "aws_acm_certificate_validation" "edge" {
  count = local.edge_cert_count

  certificate_arn = var.edge_certificate_arn

  # Record written before the retry → ISSUED within minutes. 60m leaves room for
  # the customer to add the custom-app_domain CNAME (pavo-cert-aws) without
  # eating the whole Omnistrate apply window.
  timeouts {
    create = "60m"
  }

  lifecycle {
    precondition {
      condition     = startswith(var.edge_certificate_arn, "arn:aws:acm:")
      error_message = <<-EOT
        network_posture = "strict" requires edge_certificate_arn to be the ACM ARN
        pavoCert emits as certificate_arn, got "${var.edge_certificate_arn}".
        Empty: pavoCert did not apply. A literal template: the spec's
        $pavoCert.out.certificate_arn reference did not resolve.
      EOT
    }
  }
}
