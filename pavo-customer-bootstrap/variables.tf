# -----------------------------------------------------------------------------
# Inputs — pavo-customer-bootstrap
# -----------------------------------------------------------------------------
# Customer-scoped (one apply per `customer_name`). All Zitadel resources are
# global per-customer in Pavo's identity tenant.
#
# Structural rule (P0.7): this module MUST NOT declare `instance_id`. The
# customer-stable auth hostname is `https://${customer_name}.${base_domain}`
# and depends only on `customer_name` + `base_domain`. If we ever need
# per-instance redirect URIs, the OIDC app ownership must be redesigned.
# -----------------------------------------------------------------------------

variable "customer_name" {
  description = "Customer name. Used as the Zitadel org name (globally unique in Pavo's Zitadel tenant) and as the subdomain in the customer-stable auth hostname (https://<customer_name>.<base_domain>). Must be a valid DNS label."
  type        = string

  validation {
    # DNS label rules — RFC 1123: letters/digits/hyphens, 1-63 chars, no
    # leading/trailing hyphen, lowercase. customer_name lands directly in a
    # URL subdomain, so invalid labels break redirect URIs / OIDC callbacks.
    condition = (
      trimspace(var.customer_name) == var.customer_name &&
      can(regex("^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$", var.customer_name))
    )
    error_message = "customer_name must be a lowercase DNS label (letters, digits, hyphens; 1-63 chars; no leading/trailing hyphen)."
  }
}

variable "base_domain" {
  description = "Public base domain (e.g. pavoai.com). Redirect URIs and the login default redirect are derived as https://<customer_name>.<base_domain>/..."
  type        = string

  validation {
    # Domain syntax only — no scheme, no path, no port, no trailing space.
    # The lower(...) call accepts mixed-case input but the comparison is
    # case-insensitive (Zitadel and DNS resolvers don't care).
    condition = (
      trimspace(var.base_domain) == var.base_domain &&
      can(regex("^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$", lower(var.base_domain)))
    )
    error_message = "base_domain must be a valid domain like pavoai.com (no scheme, path, port, or whitespace)."
  }
}

variable "zitadel_pat" {
  description = "Pavo's Zitadel admin Personal Access Token for the central `auth.pavoai.com`. Belongs to Pavo (not the customer); supply via env var or -var-file at apply time. Leave empty for the in-VPC self-hosted path, which authenticates with a machine KEY via zitadel_jwt_profile_file instead."
  type        = string
  sensitive   = true
  default     = ""
  # No non-empty validation: the self-hosted path uses zitadel_jwt_profile_file
  # instead. TF variable validation can't cross-reference another var, so the
  # "exactly one auth method" requirement is enforced by the zitadel provider at
  # apply time.
}

# -----------------------------------------------------------------------------
# Zitadel endpoint — central (cloud) by default; overridden for the in-VPC path
# -----------------------------------------------------------------------------
# Defaults keep the existing central apply byte-for-byte unchanged
# (auth.pavoai.com : 443, verified TLS, PAT auth). The in-VPC self-hosted
# Provision Job overrides all four: the instance's auth_hostname, port 8080, an
# insecure connection (the internal self-signed cert is skip-verified in-cluster
# — the token signature is the real trust boundary), and machine-KEY auth.
variable "zitadel_domain" {
  description = "Zitadel host. Central/cloud = auth.pavoai.com; in-VPC self-hosted = the instance's resolved auth_hostname (e.g. auth.<customer>.pavoai.dev)."
  type        = string
  default     = "auth.pavoai.com"
}

variable "zitadel_port" {
  description = "Zitadel API port. 443 for central; 8080 for the in-VPC ClusterIP svc."
  type        = string
  default     = "443"
}

variable "zitadel_insecure" {
  description = "Skip TLS verification of the Zitadel endpoint. false for central (public LE cert); true for the in-VPC internal self-signed cert."
  type        = bool
  default     = false
}

variable "zitadel_jwt_profile_file" {
  description = "Path to a Zitadel machine-user KEY JSON for JWT-profile auth (the in-VPC Provision Job mounts the FirstInstance key here). Empty → use zitadel_pat (central/cloud)."
  type        = string
  default     = ""
}

# -----------------------------------------------------------------------------
# Primary external identity provider (customer-scoped)
# -----------------------------------------------------------------------------
# Pavo ops sets these per customer. When `automation_enabled = false` (or no
# IdP variables are set), no `zitadel_org_idp_*` resources or login policy
# are created — the bare org/project/OIDC app still get provisioned, which is
# the right shape for a greenfield customer that doesn't have an IdP yet.

variable "login_policy_second_factors" {
  description = <<-EOT
    Second-factor methods offered by the org's login policy (e.g.
    ["SECOND_FACTOR_TYPE_OTP", "SECOND_FACTOR_TYPE_U2F"]).

    Default [] matches every customer this module manages today and is what the
    resource previously hardcoded. It is a VARIABLE rather than a literal because
    a hardcoded [] silently STRIPS whatever an org already has: importing an
    existing org with TOTP and security keys enabled would remove both on the
    first apply, with no signal beyond a line in the plan. force_mfa is false, so
    nothing would fail loudly — users would simply find their second factor gone.

    Set this to the org's existing methods when adopting an org that was created
    outside this module, so the import is a genuine no-op.
  EOT
  type        = list(string)
  default     = []
}

variable "login_policy_multi_factors" {
  description = <<-EOT
    Multi-factor methods offered by the org's login policy (e.g.
    ["MULTI_FACTOR_TYPE_U2F_WITH_VERIFICATION"]). Same rationale and same
    adoption caveat as login_policy_second_factors above.
  EOT
  type        = list(string)
  default     = []
}

variable "primary_external_identity_provider_automation_enabled" {
  description = "Master switch. When true and the IdP variables below are populated, provision `zitadel_org_idp_*` and the login policy."
  type        = bool
  default     = false
}

variable "primary_external_identity_provider_type" {
  description = "One of `google`, `okta`, `oidc`. Empty disables IdP automation."
  type        = string
  default     = ""

  validation {
    # A typo like `okt` would silently disable IdP automation (the `contains
    # (["okta", "oidc"], ...)` checks in the derived locals would return
    # false, no IdP resources created, no error). Fail fast on unknown values
    # so the operator catches the typo at plan time.
    condition = contains(
      ["", "google", "okta", "oidc"],
      lower(trimspace(var.primary_external_identity_provider_type)),
    )
    error_message = "primary_external_identity_provider_type must be one of: '', 'google', 'okta', 'oidc'."
  }
}

variable "primary_external_identity_provider_label" {
  description = "Optional override for the frontend 'Continue with X' button text. Empty falls back to a type-specific default (`Continue with Google`, `Continue with Okta`, `Continue with SSO`). Does NOT affect the Zitadel IdP resource's `name` argument — that's always the type-default (`Google` / `Okta` / `SSO`)."
  type        = string
  default     = ""
}

variable "primary_external_identity_provider_prompt" {
  description = "Optional override for the OAuth `prompt` query parameter on authorize URLs. Empty falls back to `select_account` for `google`, empty for all other types. Ignored entirely for SAML."
  type        = string
  default     = ""
}

variable "primary_external_identity_provider_client_id" {
  description = "OAuth/OIDC client ID. Required for `google` and `oidc`/`okta`-with-OIDC types; ignored for SAML."
  type        = string
  sensitive   = true
  default     = ""
}

variable "primary_external_identity_provider_client_secret" {
  description = "OAuth/OIDC client secret. Required for `google` and `oidc`/`okta`-with-OIDC types; ignored for SAML."
  type        = string
  sensitive   = true
  default     = ""
}

variable "primary_external_identity_provider_oidc_issuer" {
  description = "OIDC issuer URL. Required when `type` is `oidc` or `okta` and the IdP exposes OIDC. Mutually exclusive with `saml_metadata_url`."
  type        = string
  default     = ""
}

variable "primary_external_identity_provider_saml_metadata_url" {
  description = "SAML metadata URL. Required when `type` is `okta`/`oidc` and the IdP only exposes SAML. Mutually exclusive with `oidc_issuer`."
  type        = string
  default     = ""
}

# -----------------------------------------------------------------------------
# Derived locals — same logic as the pre-rescope pavoInfra version, copied
# intact so the module behavior matches what `terraform-omnistrate-aws` did.
# -----------------------------------------------------------------------------

locals {
  # ---- normalized inputs (trim + lowercase where appropriate) -------------
  primary_external_identity_provider_type              = lower(trimspace(var.primary_external_identity_provider_type))
  primary_external_identity_provider_client_id         = trimspace(var.primary_external_identity_provider_client_id)
  primary_external_identity_provider_client_secret     = trimspace(var.primary_external_identity_provider_client_secret)
  primary_external_identity_provider_oidc_issuer       = trimspace(var.primary_external_identity_provider_oidc_issuer)
  primary_external_identity_provider_saml_metadata_url = trimspace(var.primary_external_identity_provider_saml_metadata_url)
  primary_external_identity_provider_label_input       = trimspace(var.primary_external_identity_provider_label)
  primary_external_identity_provider_prompt_input      = trimspace(var.primary_external_identity_provider_prompt)

  # ---- type/flow detection ------------------------------------------------
  primary_external_identity_provider_uses_generic_oidc = contains(
    ["okta", "oidc"],
    local.primary_external_identity_provider_type,
  )

  primary_external_identity_provider_uses_saml = (
    local.primary_external_identity_provider_uses_generic_oidc &&
    local.primary_external_identity_provider_saml_metadata_url != ""
  )

  primary_external_identity_provider_has_oidc_automation_credentials = (
    local.primary_external_identity_provider_client_id != "" &&
    local.primary_external_identity_provider_client_secret != ""
  )

  # ---- automation flags ---------------------------------------------------
  primary_external_identity_provider_oidc_automation_enabled = (
    var.primary_external_identity_provider_automation_enabled &&
    !local.primary_external_identity_provider_uses_saml &&
    local.primary_external_identity_provider_has_oidc_automation_credentials &&
    (
      local.primary_external_identity_provider_type == "google" ||
      (
        local.primary_external_identity_provider_uses_generic_oidc &&
        local.primary_external_identity_provider_oidc_issuer != ""
      )
    )
  )

  primary_external_identity_provider_saml_automation_enabled = (
    var.primary_external_identity_provider_automation_enabled &&
    local.primary_external_identity_provider_uses_saml
  )

  primary_external_identity_provider_automation_enabled = (
    local.primary_external_identity_provider_oidc_automation_enabled ||
    local.primary_external_identity_provider_saml_automation_enabled
  )

  # ---- computed presentation values (Zitadel IdP arg + frontend UI) ------
  # Three distinct values — DO NOT conflate:
  #
  #   display_name      → Zitadel IdP resource's `name` arg (Zitadel admin UI).
  #                       Always the type-default; never the operator's label.
  #
  #   button_label      → Frontend "Continue with X" button text.
  #                       Operator label override OR type-default fallback.
  #
  #   authorize_prompt  → OAuth `prompt` query param sent to the IdP at /authorize.
  #                       Operator prompt override OR `select_account` for google,
  #                       empty otherwise.
  primary_external_identity_provider_display_name = (
    local.primary_external_identity_provider_type == "google" ? "Google" :
    local.primary_external_identity_provider_type == "okta" ? "Okta" :
    local.primary_external_identity_provider_type == "oidc" ? "SSO" :
    ""
  )

  primary_external_identity_provider_button_label = (
    local.primary_external_identity_provider_label_input != "" ? local.primary_external_identity_provider_label_input :
    local.primary_external_identity_provider_type == "google" ? "Continue with Google" :
    local.primary_external_identity_provider_type == "okta" ? "Continue with Okta" :
    local.primary_external_identity_provider_type == "oidc" ? "Continue with SSO" :
    ""
  )

  # SAML flows ignore the OAuth `prompt` parameter entirely — the input
  # variable's description says so, but the truth lives here: if SAML
  # automation is active, force authorize_prompt to "" regardless of any
  # operator override. (Otherwise an operator who sets `prompt = "consent"`
  # for a SAML customer would silently leak a non-empty value into
  # pavoInfra's `primary_external_identity_provider_prompt` output, which
  # the frontend would dutifully tack onto an OAuth /authorize URL —
  # except this customer doesn't have an OAuth flow.)
  primary_external_identity_provider_authorize_prompt = (
    local.primary_external_identity_provider_uses_saml ? "" :
    local.primary_external_identity_provider_prompt_input != "" ? local.primary_external_identity_provider_prompt_input :
    local.primary_external_identity_provider_type == "google" ? "select_account" :
    ""
  )
}
