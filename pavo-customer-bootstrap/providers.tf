# -----------------------------------------------------------------------------
# Terraform Providers — pavo-customer-bootstrap
# -----------------------------------------------------------------------------
# Pavo-applied, once per customer. Owns Zitadel identity resources in Pavo's
# shared Zitadel tenant (`auth.pavoai.com`). The customer does NOT run this
# module — they don't have our Zitadel PAT.
#
# Only the Zitadel provider is needed here. No AWS, no Kubernetes, no Helm —
# those live in `pavo-bootstrap-aws/` (cell) and `terraform-omnistrate-aws/`
# (instance). See README.md → "Ownership rules" for the full model.
# -----------------------------------------------------------------------------

terraform {
  required_version = ">= 1.5"

  required_providers {
    zitadel = {
      source  = "zitadel/zitadel"
      version = "~> 2.11"
    }
  }
}

provider "zitadel" {
  domain = var.zitadel_domain
  port   = var.zitadel_port
  # `insecure` (used before) means plaintext HTTP — it made the provider dial
  # http://<host>:<port>, which fails against the in-VPC Zitadel that serves real
  # (self-signed) HTTPS on 8080. The correct knob is `insecure_skip_verify_tls`:
  # keep HTTPS, just skip verifying the self-signed cert. Central
  # (auth.pavoai.com) sets zitadel_insecure=false → full TLS verification against
  # the public LE cert; in-VPC sets true → skip-verify.
  insecure_skip_verify_tls = var.zitadel_insecure

  # Auth: the central (cloud) apply uses Pavo's PAT against auth.pavoai.com; the
  # in-VPC self-hosted Provision Job uses the FirstInstance machine KEY (JSON)
  # via JWT-profile. Exactly one is active — the other resolves to null (unset).
  access_token     = var.zitadel_jwt_profile_file != "" ? null : var.zitadel_pat
  jwt_profile_file = var.zitadel_jwt_profile_file != "" ? var.zitadel_jwt_profile_file : null
}
