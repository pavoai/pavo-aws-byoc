# -----------------------------------------------------------------------------
# Outputs — pavo-customer-bootstrap
# -----------------------------------------------------------------------------
# Consumed by Pavo ops, not by other Terraform states. Pavo ops captures these
# after `terraform apply` and feeds them into `terraform-omnistrate-aws`'s
# instance-create apiParameters via scripts/create-aws-instance.sh.
#
# zitadel_oidc_client_secret is marked sensitive so it's redacted in CLI output
# and not written to the state diff in plaintext. Read it with:
#   terraform output -raw zitadel_oidc_client_secret
# -----------------------------------------------------------------------------

output "zitadel_org_id" {
  description = "Zitadel organization ID for this customer. Becomes pavoInfra's `var.zitadel_org_id`."
  value       = zitadel_org.customer.id
}

output "zitadel_project_id" {
  description = "Zitadel project ID. Becomes pavoInfra's `var.zitadel_project_id`."
  value       = zitadel_project.pavo.id
}

output "zitadel_oidc_client_id" {
  description = "OIDC client ID for the customer's web app. Becomes pavoInfra's `var.zitadel_oidc_client_id`."
  # The Zitadel provider marks `zitadel_application_oidc.client_id` as
  # sensitive (matches the `sensitive = true` on pavoInfra's
  # `var.zitadel_oidc_client_id`). Without `sensitive = true` here, Terraform
  # refuses to plan with `Error: Output refers to sensitive values`. The
  # client_id isn't truly secret — the frontend embeds it base64-encoded —
  # but we honor the provider's sensitivity marking so `terraform output`
  # (no `-raw`) redacts it. Read with `terraform output -raw zitadel_oidc_client_id`.
  value     = zitadel_application_oidc.pavo_web.client_id
  sensitive = true
}

output "zitadel_oidc_client_secret" {
  description = "OIDC client secret. Becomes pavoInfra's `var.zitadel_oidc_client_secret` (Omnistrate `type: Password`)."
  value       = zitadel_application_oidc.pavo_web.client_secret
  sensitive   = true
}

output "zitadel_issuer" {
  description = "Zitadel OIDC issuer URL. Becomes pavoInfra's `var.zitadel_issuer`. Derived from the provider's `domain` setting in providers.tf — change both together if Pavo ever moves to a different Zitadel host."
  value       = "https://${var.zitadel_domain}"
}

# -----------------------------------------------------------------------------
# Identity runtime outputs — full pavoInfra output-contract surface
# -----------------------------------------------------------------------------
# customer-bootstrap is the single source of truth for every identity value
# pavoInfra needs to expose to api-gateway / frontend / operators. pavoInfra
# takes these in as variables and either passes them through or base64-encodes
# them (the only allowed transform — pure function, no Zitadel knowledge).
#
# Adding a new identity output? Add it here, add a corresponding apiParameter
# to spec/spec-byoc.yaml (both pavoInfra and pavo-platform service blocks),
# add a var in terraform-omnistrate-aws/variables.tf, pass through in
# terraform-omnistrate-aws/outputs.tf. Update scripts/inject-zitadel-params.sh
# and scripts/create-aws-instance.sh to wire the new value.
# -----------------------------------------------------------------------------

output "zitadel_org_primary_domain" {
  description = "Customer-stable Zitadel organization domain (e.g. `<customer_name>.auth.pavoai.com`). Becomes pavoInfra's `var.zitadel_org_primary_domain`."
  value       = "${var.customer_name}.${var.zitadel_domain}"
}

output "zitadel_idp_id" {
  description = "Zitadel IdP ID for OAuth IdP flows (google / oidc — NOT SAML; SAML uses `primary_external_identity_provider_saml_idp_id`). Empty when no OAuth IdP is configured. pavoInfra base64-encodes this for the frontend."
  value = try(
    concat(
      zitadel_org_idp_google.primary_external_identity_provider[*].id,
      zitadel_org_idp_oidc.primary_external_identity_provider[*].id,
    )[0],
    "",
  )
}

output "primary_external_identity_provider_enabled" {
  description = "Whether this customer's frontend should expose a primary external identity provider button. True when both `automation_enabled = true` and a valid IdP credential set was supplied."
  # `automation_enabled` transitively depends on `var.…_client_id` /
  # `var.…_client_secret` (sensitive vars) via `has_oidc_automation_credentials`,
  # so Terraform marks this local sensitive even though the boolean
  # truth-value isn't itself a secret. `nonsensitive()` explicitly opts the
  # bool out — Pavo ops needs to read it via `terraform output` to plumb it
  # through to pavoInfra's `apiParameter`. The downstream outputs in this
  # file (type/label/prompt/saml_*) return strings derived through a
  # conditional, which Terraform's taint analysis does NOT propagate as
  # sensitive — only the bare bool here trips the check.
  value = nonsensitive(local.primary_external_identity_provider_automation_enabled)
}

output "primary_external_identity_provider_type" {
  description = "IdP type label for the frontend (`google` / `okta` / `oidc`). Empty when no IdP is active."
  value = nonsensitive(
    local.primary_external_identity_provider_automation_enabled ?
    local.primary_external_identity_provider_type :
    ""
  )
}

output "primary_external_identity_provider_label" {
  description = "Frontend 'Continue with X' button text. Operator override OR type-specific default."
  value = nonsensitive(
    local.primary_external_identity_provider_automation_enabled ?
    local.primary_external_identity_provider_button_label :
    ""
  )
}

output "primary_external_identity_provider_prompt" {
  description = "OAuth `prompt` query parameter the frontend should send to the IdP. `select_account` default for google; empty for other types unless operator-overridden."
  value = nonsensitive(
    local.primary_external_identity_provider_automation_enabled ?
    local.primary_external_identity_provider_authorize_prompt :
    ""
  )
}

output "primary_external_identity_provider_saml_idp_id" {
  description = "Zitadel SAML IdP numeric ID — used to construct the SP metadata URL. Empty when SAML is not active for this customer."
  value = (
    local.primary_external_identity_provider_saml_automation_enabled ?
    tostring(zitadel_org_idp_saml.primary_external_identity_provider[0].id) :
    ""
  )
}

output "primary_external_identity_provider_saml_sp_metadata_url" {
  description = "Zitadel SAML Service Provider metadata URL — paste into the customer IdP admin (e.g. Okta SAML app's 'Audience URI / SP Entity ID' field). Empty when SAML not active."
  value = (
    local.primary_external_identity_provider_saml_automation_enabled ?
    "https://${var.zitadel_domain}/idps/${zitadel_org_idp_saml.primary_external_identity_provider[0].id}/saml/metadata" :
    ""
  )
}

output "primary_external_identity_provider_saml_sp_entity_id" {
  description = "Zitadel SAML SP EntityID. Today identical to `sp_metadata_url` (Okta accepts the metadata URL as the EntityID). Kept as a separate output for explicitness; if the contract ever diverges, change here. Empty when SAML not active."
  value = (
    local.primary_external_identity_provider_saml_automation_enabled ?
    "https://${var.zitadel_domain}/idps/${zitadel_org_idp_saml.primary_external_identity_provider[0].id}/saml/metadata" :
    ""
  )
}

output "primary_external_identity_provider_saml_acs_url" {
  description = "Zitadel SAML Assertion Consumer Service URL — tenant-wide constant. Paste into the customer IdP admin's 'Single Sign-On URL' field. Empty when SAML not active."
  value = (
    local.primary_external_identity_provider_saml_automation_enabled ?
    "https://${var.zitadel_domain}/ui/login/login/externalidp/saml/acs" :
    ""
  )
}
