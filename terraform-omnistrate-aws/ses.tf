# -----------------------------------------------------------------------------
# Amazon SES sending identity (email_enabled only)
#
# AWS instances send transactional email via SES. This provisions the SES v2
# domain identity for the instance's sending domain with Easy DKIM, and outputs
# the DKIM CNAME tokens for the operator/customer to publish. Two manual,
# per-account steps remain (runbook): publish these DKIM records, and move the
# account out of the SES sandbox before go-live.
#
# The SES VPC interface endpoint (so the SendEmail call never leaves the VPC in
# a strict cell) is added by vpc_endpoints.tf; the ses:SendEmail IRSA grant is
# in main.tf. All three are gated on email_enabled.
# -----------------------------------------------------------------------------

locals {
  # Resolve the email_enabled string sentinel to a bool for resource gating.
  # Empty derives the posture-aware default (off for self_hosted/IdP-only, on
  # for cloud) — matching the old enable_email_login behavior.
  email_enabled = var.email_enabled != "" ? var.email_enabled == "true" : !local.zitadel_self_hosted
}

resource "aws_sesv2_email_identity" "sending_domain" {
  count          = local.email_enabled ? 1 : 0
  email_identity = local.app_domain

  dkim_signing_attributes {
    next_signing_key_length = "RSA_2048_BIT"
  }
}

output "ses_dkim_tokens" {
  description = "DKIM token hostnames to publish as CNAMEs on the sending domain (email_enabled only; empty when email is disabled). Each <token> -> <token>.dkim.amazonses.com."
  value       = local.email_enabled ? aws_sesv2_email_identity.sending_domain[0].dkim_signing_attributes[0].tokens : []
}
