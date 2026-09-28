# -----------------------------------------------------------------------------
# Per-customer scope.
#
# Resources here are global per-customer in Pavo's identity tenant. Applied by
# Pavo (not the customer), once per `customer_name`. Outputs are passed to the
# per-instance pavoInfra as regular instance-create apiParameters by Pavo ops
# (see scripts/create-aws-instance.sh in the repo root).
#
# Do NOT add cell-scoped or instance-scoped resources here. Those belong in
# `pavo-bootstrap-aws/` (cell) or `terraform-omnistrate-aws/` (instance).
#
# See README.md → "Ownership rules" for the full model.
# -----------------------------------------------------------------------------

# One Organization per customer (isolated tenant in the shared Zitadel instance).
# The `name` is globally unique in Pavo's Zitadel tenant; conflict with another
# customer of the same name is what wedged every prior test-instance respawn
# before this rescope.
resource "zitadel_org" "customer" {
  name = var.customer_name

  lifecycle {
    # Guard against accidental destroy. Same rationale as terraform-legacy and
    # terraform-omnistrate-gcp (incident 2026-06-10). Deliberate decommission
    # requires a two-PR sequence: (1) remove this lifecycle block, (2) drop the
    # resource.
    prevent_destroy = true

    precondition {
      condition = !(
        local.primary_external_identity_provider_oidc_issuer != "" &&
        local.primary_external_identity_provider_saml_metadata_url != ""
      )
      error_message = "Set only one of oidc_issuer or saml_metadata_url on primary_external_identity_provider for a customer — not both."
    }
  }
}

# One Project per customer (scoped to their org).
resource "zitadel_project" "pavo" {
  org_id = zitadel_org.customer.id
  name   = "Pavo Platform"

  # See zitadel_org.customer above — same guard. The project owns the OIDC
  # app's client_id/secret; destroy+recreate rotates those silently and
  # breaks every frontend that pinned them.
  lifecycle {
    prevent_destroy = true
  }
}

# OIDC web application — consumed by frontend + api-gateway.
# Redirect URIs depend ONLY on customer_name + base_domain (no instance_id).
# This is the structural invariant the module enforces.
resource "zitadel_application_oidc" "pavo_web" {
  org_id     = zitadel_org.customer.id
  project_id = zitadel_project.pavo.id

  name = "${var.customer_name}-pavo-web"

  redirect_uris = [
    "https://${var.customer_name}.${var.base_domain}/login/oidc-callback",
    "http://localhost:3000/login/oidc-callback",
  ]

  app_type          = "OIDC_APP_TYPE_WEB"
  response_types    = ["OIDC_RESPONSE_TYPE_CODE"]
  grant_types       = ["OIDC_GRANT_TYPE_AUTHORIZATION_CODE"]
  auth_method_type  = "OIDC_AUTH_METHOD_TYPE_BASIC"
  dev_mode          = false
  access_token_type = "OIDC_TOKEN_TYPE_BEARER"

  post_logout_redirect_uris = []

  # See zitadel_org.customer above — same guard. Destroy+recreate rotates
  # client_id and client_secret; every consumer that pinned them (frontend,
  # api-gateway) breaks until manually updated.
  lifecycle {
    prevent_destroy = true
  }
}

resource "zitadel_org_idp_google" "primary_external_identity_provider" {
  count = (
    local.primary_external_identity_provider_automation_enabled &&
    local.primary_external_identity_provider_type == "google"
  ) ? 1 : 0

  org_id        = zitadel_org.customer.id
  name          = local.primary_external_identity_provider_display_name
  client_id     = local.primary_external_identity_provider_client_id
  client_secret = local.primary_external_identity_provider_client_secret
  scopes        = ["openid", "profile", "email"]

  is_linking_allowed  = true
  is_creation_allowed = true
  is_auto_creation    = true
  is_auto_update      = true
  auto_linking        = "AUTO_LINKING_OPTION_EMAIL"

  # See zitadel_org.customer above — same guard. Empty Google client_id/secret
  # would flip automation_enabled false and silently destroy the IdP.
  lifecycle {
    prevent_destroy = true
  }
}

resource "zitadel_org_idp_oidc" "primary_external_identity_provider" {
  count = (
    local.primary_external_identity_provider_oidc_automation_enabled &&
    local.primary_external_identity_provider_uses_generic_oidc
  ) ? 1 : 0

  org_id        = zitadel_org.customer.id
  name          = local.primary_external_identity_provider_display_name
  client_id     = local.primary_external_identity_provider_client_id
  client_secret = local.primary_external_identity_provider_client_secret
  issuer        = local.primary_external_identity_provider_oidc_issuer
  scopes        = ["openid", "profile", "email"]

  is_linking_allowed  = true
  is_creation_allowed = true
  is_auto_creation    = true
  is_auto_update      = true
  is_id_token_mapping = false
  use_pkce            = true
  auto_linking        = "AUTO_LINKING_OPTION_EMAIL"

  # See zitadel_org.customer above — same guard.
  lifecycle {
    prevent_destroy = true
  }
}

resource "zitadel_org_idp_saml" "primary_external_identity_provider" {
  count = local.primary_external_identity_provider_saml_automation_enabled ? 1 : 0

  org_id                   = zitadel_org.customer.id
  name                     = local.primary_external_identity_provider_display_name
  metadata_url             = local.primary_external_identity_provider_saml_metadata_url
  binding                  = "SAML_BINDING_POST"
  name_id_format           = "SAML_NAME_ID_FORMAT_EMAIL_ADDRESS"
  with_signed_request      = false
  federated_logout_enabled = false

  is_linking_allowed  = true
  is_creation_allowed = true
  is_auto_creation    = true
  is_auto_update      = true
  auto_linking        = "AUTO_LINKING_OPTION_EMAIL"

  # See zitadel_org.customer above — same guard.
  lifecycle {
    prevent_destroy = true
  }
}

# Pre-fill the Zitadel user profile from SAML attribute statements so end-users
# don't see a registration form on first login. The script's function name must
# match the action's name. Contract with every SAML customer's IdP admin: emit
# attribute statements named emailaddress, givenname, surname (Basic format).
resource "zitadel_action" "prefill_saml_register" {
  count = local.primary_external_identity_provider_saml_automation_enabled ? 1 : 0

  org_id          = zitadel_org.customer.id
  name            = "prefillRegisterFromSAML"
  timeout         = "10s"
  allowed_to_fail = false

  script = <<-EOT
    function prefillRegisterFromSAML(ctx, api) {
      if (ctx.v1.externalUser.externalIdpId != "${zitadel_org_idp_saml.primary_external_identity_provider[0].id}") return
      let firstname = ctx.v1.providerInfo.attributes["givenname"];
      let lastname  = ctx.v1.providerInfo.attributes["surname"];
      let email     = ctx.v1.providerInfo.attributes["emailaddress"];
      if (firstname != undefined) api.setFirstName(firstname[0]);
      if (lastname  != undefined) api.setLastName(lastname[0]);
      if (email     != undefined) {
        api.setEmail(email[0]);
        api.setEmailVerified(true);
        api.setPreferredUsername(email[0]);
      }
    }
  EOT
}

resource "zitadel_trigger_actions" "prefill_saml_register" {
  count = local.primary_external_identity_provider_saml_automation_enabled ? 1 : 0

  org_id       = zitadel_org.customer.id
  flow_type    = "FLOW_TYPE_EXTERNAL_AUTHENTICATION"
  trigger_type = "TRIGGER_TYPE_POST_AUTHENTICATION"
  action_ids   = [zitadel_action.prefill_saml_register[0].id]
}

resource "zitadel_login_policy" "primary_external_identity_provider" {
  count = local.primary_external_identity_provider_automation_enabled ? 1 : 0

  org_id = zitadel_org.customer.id

  user_login                    = false
  allow_register                = false
  allow_external_idp            = true
  force_mfa                     = false
  force_mfa_local_only          = false
  passwordless_type             = "PASSWORDLESS_TYPE_NOT_ALLOWED"
  hide_password_reset           = false
  password_check_lifetime       = "240h0m0s"
  external_login_check_lifetime = "240h0m0s"
  multi_factor_check_lifetime   = "12h0m0s"
  mfa_init_skip_lifetime        = "0h0m0s"
  second_factor_check_lifetime  = "18h0m0s"
  ignore_unknown_usernames      = true
  default_redirect_uri          = "https://${var.customer_name}.${var.base_domain}/login"
  second_factors                = var.login_policy_second_factors
  multi_factors                 = var.login_policy_multi_factors
  idps = concat(
    zitadel_org_idp_google.primary_external_identity_provider[*].id,
    zitadel_org_idp_oidc.primary_external_identity_provider[*].id,
    zitadel_org_idp_saml.primary_external_identity_provider[*].id,
  )
  allow_domain_discovery   = false
  disable_login_with_email = true
  disable_login_with_phone = true

  # See zitadel_org.customer above — same guard. Destroying the per-org login
  # policy makes the org inherit the instance-default.
  lifecycle {
    prevent_destroy = true
  }
}
