# -----------------------------------------------------------------------------
# Terraform Variables — AWS module
# -----------------------------------------------------------------------------
# Injected by Omnistrate at deployment time:
# - $sys.* values are resolved from the deployment cell
# - $var.* values come from API parameters
# - $secret.* values come from Omnistrate secret store
# -----------------------------------------------------------------------------

# -----------------------------------------------------------------------------
# System Parameters (injected by Omnistrate from deployment cell)
# -----------------------------------------------------------------------------

variable "aws_region" {
  description = "AWS region (from $sys.deploymentCell.region)"
  type        = string
  default     = "us-east-1"
}

variable "vpc_id" {
  description = "VPC ID for private connectivity (from $sys.deploymentCell.cloudProviderNetworkID)"
  type        = string
}

variable "eks_cluster_name" {
  description = "EKS cluster name for kubernetes provider auth (from $sys.deploymentCell.kubernetesClusterID)"
  type        = string
}

variable "eks_oidc_provider" {
  description = "EKS OIDC provider URL without https:// (from $sys.deploymentCell.oidcIssuerID)"
  type        = string
}

variable "instance_id" {
  description = "Unique deployment instance ID for resource naming (from $sys.id)"
  type        = string
}

# -----------------------------------------------------------------------------
# API Parameters (provided at deployment time via $var.*)
# -----------------------------------------------------------------------------

variable "customer_name" {
  description = "Customer identifier used for resource naming"
  type        = string

  validation {
    condition     = length(trimspace(var.customer_name)) > 0 && can(regex("^[a-z][a-z0-9-]*$", var.customer_name))
    error_message = "customer_name must be a non-empty lowercase string starting with a letter."
  }
}

variable "ghcr_dockerconfig" {
  description = <<-EOT
    ghcr.io dockerconfigjson (org-scoped pavoai read credential, same one the
    service Helm charts use for image pulls). Materialized as the
    `pavo-ghcr-signature-pull` Secret in the instance namespace so the cell's
    Sigstore policy-controller can authenticate to private ghcr.io to fetch
    cosign signatures/attestations under enforce (referenced by each
    ClusterImagePolicy authority's signaturePullSecrets in pavo-bootstrap-aws).
    Reuses an existing credential + egress path — no new secret or destination.
  EOT
  type        = string
  default     = ""
  sensitive   = true
}

variable "base_domain" {
  description = "Fallback base domain for customer frontends when app_domain is empty (e.g., 'pavoai.dev')."
  type        = string
  default     = "pavoai.dev"
}

variable "app_domain" {
  description = "Public domain the app is served on (frontend host; API is served at api.<app_domain>). Empty derives <customer_name>.<base_domain>."
  type        = string
  default     = ""

  validation {
    condition     = var.app_domain == "" || can(regex("^[a-z0-9.-]+\\.[a-z]{2,}$", var.app_domain))
    error_message = "app_domain must be a bare hostname like 'app.pavoai.com' (no scheme, path, port, or whitespace), or empty to derive <customer_name>.<base_domain>."
  }
}

variable "extra_cors_origins" {
  description = "Additional S3 CORS origins for direct Terraform module consumers. Not exposed as an Omnistrate apiParameter."
  type        = list(string)
  default     = []
}

variable "db_instance_class" {
  description = "RDS instance class for the PostgreSQL instance"
  type        = string
  default     = "db.r6g.large"
}

variable "postgres_engine_version" {
  description = <<-EOT
    RDS PostgreSQL engine version for the app + (self-hosted) Temporal databases.
    NOT hardcoded: AWS retires specific minor versions over time, and a pinned
    minor keeps working for existing (grandfathered) instances while silently
    breaking the NEXT new-instance create ("Cannot find version X for postgres").
    Bump this default to a currently-creatable minor when AWS deprecates the old
    one. Check with:
      aws rds describe-db-engine-versions --engine postgres --region <region> \
        --query 'DBEngineVersions[?starts_with(EngineVersion, `16.`)].[EngineVersion,Status]'
  EOT
  type        = string
  default     = "16.14"
}

variable "rds_deletion_protection" {
  description = "Whether to enable RDS API-level deletion protection. Set to false for test deployments."
  type        = bool
  default     = true
}

variable "cell_kms_key_arn" {
  description = "The cell's single customer-managed KMS key ARN (or alias ARN) — encrypts the following at rest under the customer's own key: RDS storage + master-password secret, application S3 (onboarding + intern_data), EFS (filesystems created on strict-posture instances; an existing filesystem keeps its key), self-hosted Elasticsearch EBS + snapshots, and Zitadel resources (and, in pavo-bootstrap-aws, the in-VPC observability volumes). One key for the whole deployment: least customer effort, uniform key custody. Renamed from db_kms_key_arn (it never only covered the DB). Required. Both 'arn:aws:kms:...:key/UUID' and 'arn:aws:kms:...:alias/name' formats are accepted. NOTE: this supports only the commercial AWS partition (arn:aws:...). GovCloud and China partitions require partition-aware policy resources (policy-statements.json hardcodes 'arn:aws:' in many resource ARNs); deferred to a follow-up."
  type        = string

  validation {
    # Commercial AWS partition only. Accepts key/ and alias/ prefixes, MRK keys
    # (mrk-*), UUIDs, and arbitrary alias names.
    condition     = can(regex("^arn:aws:kms:[a-z0-9-]+:[0-9]+:(key|alias)/.+$", var.cell_kms_key_arn))
    error_message = "cell_kms_key_arn must be a valid commercial AWS KMS key or alias ARN (arn:aws:kms:...). GovCloud / China partitions are not supported in this PR — see variable description."
  }
}

# -----------------------------------------------------------------------------
# Secrets (stored in Omnistrate UI, not in git - via $secret.*)
# -----------------------------------------------------------------------------

variable "elastic_api_key" {
  description = "Elastic Cloud API key (for ec provider)"
  type        = string
  sensitive   = true
}

variable "elastic_cloud_region" {
  description = "Elastic Cloud region for the ES deployment (e.g. us-east-2)."
  type        = string
}

variable "elasticsearch_api_key" {
  description = "Elasticsearch API key (for imported clusters)"
  type        = string
  sensitive   = true
  default     = ""
}

variable "es_mode" {
  description = <<-EOT
    Elasticsearch backend for this instance — the "cloud vs self-hosted" knob for
    ES ONLY. Deliberately per-component (es_mode / grafana_mode / zitadel_mode) so
    each self-hosted subsystem can be flipped and de-risked independently.
      - "cloud"       : external Elastic Cloud (ec_deployment) —
                        the default, unchanged behavior. App gets ES_CLOUD_ID +
                        ES_API_KEY.
      - "self_hosted" : in-VPC Elasticsearch via the ECK operator, EBS under the
                        customer CMK, snapshots to a customer S3 bucket. App gets
                        ES_HOSTS + ES_USERNAME/ES_PASSWORD + ES_CA_CERT_PATH.
    Requires the cell to have ECK installed (pavo-bootstrap-aws var.enable_eck;
    published as /pavo/cells/<cluster>/eck_ready). AWS BYOC only.
  EOT
  type        = string
  default     = "cloud"

  validation {
    condition     = contains(["cloud", "self_hosted"], var.es_mode)
    error_message = "es_mode must be either \"cloud\" or \"self_hosted\"."
  }
}

# -----------------------------------------------------------------------------
# Network posture — the "standard vs strict" zero-egress knob for a dedicated
# customer cell. strict is machine-gated on cell readiness (private CA + CNI
# NetworkPolicy support) so it cannot be entered half-configured; see the
# readiness check in network_policies.tf.
# -----------------------------------------------------------------------------
variable "network_posture" {
  description = <<-EOT
    Network posture for this instance — the "standard vs strict" zero-egress knob.
      - "standard" : today's behaviour, unchanged.
      - "strict"   : per-instance default-deny egress NetworkPolicies (only in-VPC
                     + gateway/interface-endpoint destinations reachable), an
                     internal (not internet-facing) LB scheme, and private-CA
                     ingress certs. Gated — a
                     strict instance fails fast unless the cell has the private CA
                     installed (/pavo/cells/<cluster>/private_ca_ready) AND CNI
                     NetworkPolicy support (/pavo/cells/<cluster>/network_policy_ready).
    Not yet verified on a test instance: suppression of the public DNS record. strict sets an empty
    external-dns hostname annotation, but that is a no-op if external-dns runs
    with --source=ingress rather than --source=service, and
    endpointConfiguration.networkingType stays PUBLIC (an Omnistrate-owned
    field). See the aws-lb-internal block in spec/spec-byoc.yaml.

    Dedicated strict cells only (1 cell = 1 customer). AWS BYOC only.
  EOT
  type        = string
  default     = "standard"

  validation {
    condition     = contains(["standard", "strict"], var.network_posture)
    error_message = "network_posture must be either \"standard\" or \"strict\"."
  }
}

# -----------------------------------------------------------------------------
# Observability (Grafana/metrics) mode — DEDICATED flag, decoupled from es_mode.
# Controls only where apps SEND telemetry (Grafana Cloud vs in-VPC). The in-VPC
# observability stack itself is provisioned per-cell by pavo-bootstrap-aws
# (var.enable_observability), not by this per-instance flag. It is NOT an
# Omnistrate cell amenity: the amenity module was removed in a3fef42, and
# scripts/ownership-rules-canonical.md records cell substrate belonging in
# pavo-bootstrap-aws behind an enable_* flag as a hard rule.
# -----------------------------------------------------------------------------
variable "grafana_mode" {
  description = <<-EOT
    Observability routing for this instance — the "cloud vs self-hosted" knob for
    metrics/Grafana ONLY. Separate from es_mode so observability can be flipped
    independently.
      - "self_hosted" : apps route metrics to the in-VPC observability stack (no
                        telemetry egress). This is the default. Requires the cell
                        to have been bootstrapped with enable_observability = true
                        (pavo-bootstrap-aws) so a receiver exists.
      - "cloud"       : apps egress telemetry to Grafana Cloud.
    Echoed as an output (self_hosted has no per-instance TF resources here — the
    stack is cell-scoped and owned by pavo-bootstrap-aws). AWS BYOC only.
  EOT
  type        = string
  default     = "self_hosted"

  validation {
    condition     = contains(["cloud", "self_hosted"], var.grafana_mode)
    error_message = "grafana_mode must be either \"cloud\" or \"self_hosted\"."
  }
}

# -----------------------------------------------------------------------------
# Identity hosting mode (Zitadel) — DEDICATED flag, decoupled from es_mode/grafana_mode
# -----------------------------------------------------------------------------
variable "zitadel_mode" {
  description = <<-EOT
    Where this instance's Zitadel identity provider lives — the "central vs
    in-VPC" knob for auth ONLY. Deliberately separate from es_mode/grafana_mode
    so Zitadel can be flipped and de-risked independently.
      - "cloud"       : the shared central Zitadel (auth.pavoai.com, Cloud Run in
                        onboarding-455713). Every customer is an org on it. The
                        default, unchanged behavior — apps consume the existing
                        zitadel_* pass-through vars from pavo-customer-bootstrap.
      - "self_hosted" : a per-customer Zitadel + DB running inside this instance's
                        cluster (issuer https://auth.<customer_name>.<base_domain>,
                        DB on the per-instance RDS). Auth never depends on
                        Pavo-central. Identity values are born in-cluster and
                        handed to apps via K8s Secrets/ConfigMaps, not TF vars.
    AWS BYOC (and the GCP twin). Switching is an atomic per-instance swap of the
    identity substrate, not an in-place re-point.
  EOT
  type        = string
  default     = "cloud"

  validation {
    condition     = contains(["cloud", "self_hosted"], var.zitadel_mode)
    error_message = "zitadel_mode must be either \"cloud\" or \"self_hosted\"."
  }
}

variable "auth_hostname" {
  description = <<-EOT
    Public hostname for the in-VPC Zitadel (zitadel_mode = self_hosted only).
    Empty (the default) auto-derives `auth.<customer_name>.<base_domain>` — safe
    because customer_name is unique/stable and never reused, so the derived host
    matches the app host convention (`<customer_name>.<base_domain>`). A customer
    or operator MAY set their own hostname (e.g. a strict tenant's own domain).
    Ignored when zitadel_mode = cloud.
  EOT
  type        = string
  default     = ""
}

variable "email_enabled" {
  description = <<-EOT
    Master switch for this instance's email path (login + all notifications).
    "true"  = email on: OTP login works and invitations are emailed via SES.
    "false" = strict/air-gapped: no backend wired, OTP endpoints 403, and
              invitations return a copyable link instead.
    "" (default) = derive the POSTURE-AWARE default, preserving the old
              enable_email_login behavior: OFF for self_hosted/IdP-only
              instances (email/OTP disabled, the customer IdP is the sole login
              surface), ON for cloud instances. This is a string sentinel (not
              a bool) precisely so the safe default can depend on posture — a
              renamed bool with default=true would have silently flipped every
              existing IdP-only instance to email-on on upgrade.
  EOT
  type        = string
  default     = ""

  validation {
    condition     = contains(["", "true", "false"], var.email_enabled)
    error_message = "email_enabled must be \"true\", \"false\", or \"\" (derive posture-aware default)."
  }
}

# -----------------------------------------------------------------------------
# Modal Cloud Compute (from $secret.*)
# -----------------------------------------------------------------------------

variable "modal_token_id" {
  description = "The token ID for Modal cloud compute platform."
  type        = string
  sensitive   = true
  default     = ""
}

variable "modal_token_secret" {
  description = "The token secret for Modal cloud compute platform."
  type        = string
  sensitive   = true
  default     = ""
}

# -----------------------------------------------------------------------------
# Parallel Web Search (per-customer)
# -----------------------------------------------------------------------------

variable "parallel_api_key" {
  description = "Per-tenant Parallel web-search API key, supplied by the `parallel_api_key` apiParameter at instance create/modify. Plumbed through to intern Helm via the pavoInfra.parallel_api_key output. Empty disables Parallel web search."
  type        = string
  sensitive   = true
  default     = ""
}

# -----------------------------------------------------------------------------
# Per-customer product analytics / company enrichment keys (from apiParameters)
# -----------------------------------------------------------------------------

variable "amplitude_api_key" {
  description = "Per-tenant Amplitude analytics API key, supplied by the `amplitude_api_key` apiParameter at instance create/modify. Plumbed through to intern Helm via the pavoInfra.amplitude_api_key output. Empty disables Amplitude tracking."
  type        = string
  sensitive   = true
  default     = ""
}

variable "sumble_api_key" {
  description = "Per-tenant Sumble company-enrichment API key, supplied by the `sumble_api_key` apiParameter at instance create/modify. Plumbed through to intern Helm via the pavoInfra.sumble_api_key output. Empty disables Sumble enrichment."
  type        = string
  sensitive   = true
  default     = ""
}

# -----------------------------------------------------------------------------
# api-gateway 3P integrations: HubSpot / Brevo / Langfuse (per-customer)
#
# HubSpot follows the env-secret + per-tenant override pattern. Brevo and
# Langfuse keys are per-tenant only. The *_enabled flags are per-customer kill
# switches consumed by api-gateway (HUBSPOT_ENABLED / LANGFUSE_ENABLED env vars).
# -----------------------------------------------------------------------------

variable "hubspot_api_key" {
  description = "Environment-level HubSpot private-app API key (from $secret.hubspot_api_key). Used when no per-tenant override is supplied."
  type        = string
  sensitive   = true
  default     = ""
}

variable "hubspot_api_key_override" {
  description = "Optional per-tenant override for the HubSpot API key, supplied by the `hubspot_api_key` apiParameter at instance create/modify."
  type        = string
  sensitive   = true
  default     = ""
}

variable "hubspot_client_secret" {
  description = "Environment-level HubSpot app client secret for webhook signature verification (from $secret.hubspot_client_secret). Used when no per-tenant override is supplied."
  type        = string
  sensitive   = true
  default     = ""
}

variable "hubspot_client_secret_override" {
  description = "Optional per-tenant override for the HubSpot client secret, supplied by the `hubspot_client_secret` apiParameter at instance create/modify."
  type        = string
  sensitive   = true
  default     = ""
}

variable "brevo_api_key" {
  description = "Per-tenant Brevo transactional-email API key, supplied by the `brevo_api_key` apiParameter at instance create/modify. Plumbed through to api-gateway Helm via the pavoInfra.brevo_api_key output. Empty disables Brevo email."
  type        = string
  sensitive   = true
  default     = ""
}

variable "hubspot_enabled" {
  description = "Per-customer kill switch for the HubSpot integration in api-gateway. When false (default), contact upserts on signup/login and the /hubspot/event webhook are short-circuited so no customer PII is sent to HubSpot."
  type        = bool
  default     = false
}

variable "langfuse_enabled" {
  description = "Per-customer kill switch for Langfuse LLM tracing in api-gateway. When false (default), the Langfuse SDK is hard-disabled and no prompts/completions are exported."
  type        = bool
  default     = false
}

variable "langfuse_public_key" {
  description = "Per-tenant Langfuse public key for api-gateway LLM tracing. Only used when langfuse_enabled is true."
  type        = string
  sensitive   = true
  default     = ""
}

variable "langfuse_secret_key" {
  description = "Per-tenant Langfuse secret key for api-gateway LLM tracing. Only used when langfuse_enabled is true."
  type        = string
  sensitive   = true
  default     = ""
}

variable "langfuse_host" {
  description = "Langfuse host for api-gateway LLM tracing (per-tenant; supports self-hosted/EU instances)."
  type        = string
  default     = "https://us.cloud.langfuse.com"
}

variable "temporal_payload_codec_key" {
  description = <<-EOT
    Per-customer v0 static key for intern Temporal payload encryption.
    Must be 64 hex chars (32 bytes). Future keyring/KMS work should
    replace this before long-term production use.
  EOT
  type        = string
  sensitive   = true
  default     = ""

  validation {
    condition = (
      trimspace(var.temporal_payload_codec_key) == "" ||
      can(regex("^[0-9a-fA-F]{64}$", trimspace(var.temporal_payload_codec_key)))
    )
    error_message = "temporal_payload_codec_key must be empty or a 64-character hex string (32 bytes)."
  }
}

# -----------------------------------------------------------------------------
# Temporal hosting mode — DEDICATED flag, decoupled from es_mode/grafana_mode/
# zitadel_mode (same per-component pattern, so Temporal can be flipped and
# de-risked independently).
# -----------------------------------------------------------------------------
variable "temporal_mode" {
  description = <<-EOT
    Where this instance's Temporal cluster lives — the "cloud vs in-VPC" knob for
    workflow orchestration ONLY.
      - "cloud"       : Temporal Cloud (pavo-<customer>-intern.gdv7k.tmprl.cloud)
                        — the default, unchanged behavior. intern consumes the
                        existing $secret.temporal_tls_cert/key client certs.
      - "self_hosted" : a per-instance Temporal server (frontend/history/matching/
                        worker) on this cluster, backed by a dedicated RDS
                        Postgres under the customer CMK. Workflow state never
                        leaves the VPC. Requires grafana_mode = "self_hosted"
                        (Temporal must be monitorable without Grafana Cloud
                        egress — enforced by a plan-time precondition).
    Immutable per instance: switching modes is a workflow-state migration
    (namespace + cert re-issue + drain), not an in-place re-point — spec marks
    the parameter modifiable:false. AWS BYOC only; unused on GCP.
  EOT
  type        = string
  default     = "cloud"

  validation {
    condition     = contains(["cloud", "self_hosted"], var.temporal_mode)
    error_message = "temporal_mode must be either \"cloud\" or \"self_hosted\"."
  }
}

variable "temporal_history_shards" {
  description = <<-EOT
    numHistoryShards for the self-hosted Temporal cluster. FROZEN at cluster
    creation — Temporal cannot change shard count on an existing cluster
    (change = new cluster + workflow migration). Default 128 fits per-customer
    cell load with ~100x headroom; set higher at CREATE time only for a
    known-large customer. Ignored when temporal_mode = "cloud".
  EOT
  type        = number
  default     = 128

  validation {
    condition     = contains([16, 32, 64, 128, 256, 512, 1024, 2048, 4096, 8192, 16384], var.temporal_history_shards)
    error_message = "temporal_history_shards must be a power of two between 16 and 16384 (Temporal requirement; frozen at cluster creation)."
  }
}

variable "temporal_codec_image" {
  description = <<-EOT
    Digest-pinned intern image that provides the payload-codec HTTP server
    (`python -m temporal.codec.server`) for the self-hosted Temporal Web UI,
    e.g. ghcr.io/pavoai/intern-temporal-worker@sha256:<digest>. Only used when
    temporal_mode = "self_hosted" AND temporal_payload_codec_key is set. Empty
    (default) = no codec sidecar; the Web UI shows encoded payloads.

    PINNED SEPARATELY from intern's deployed image (intern's image is helm
    desired-state, not reachable from pavoInfra) — bump this alongside intern
    releases as policy. Drift is benign until the payload-codec FORMAT version
    changes (pavo-temporal-payload-codec/v1); on a format bump this pin MUST
    move with it or UI decode fails closed (encoded blobs, never corruption).
  EOT
  type        = string
  default     = ""

  validation {
    condition = (
      trimspace(var.temporal_codec_image) == "" ||
      can(regex("^ghcr\\.io/pavoai/[a-z0-9._/-]+@sha256:[0-9a-f]{64}$", trimspace(var.temporal_codec_image)))
    )
    error_message = "temporal_codec_image must be empty or a digest-pinned ghcr.io/pavoai image (…@sha256:<64-hex>) — the registry the cosign policy enforces."
  }
}

variable "gemini_api_key" {
  description = "Google Gemini API key for AI-powered browser actions."
  type        = string
  sensitive   = true
  default     = ""
}

variable "anthropic_api_key" {
  description = "Per-tenant Anthropic API key, supplied by the `anthropic_api_key` apiParameter at instance create/modify. Used by tribal V8 book generation fallback/sub-generators; plumbed through to onboarding Helm via the pavoInfra.anthropic_api_key output."
  type        = string
  sensitive   = true
}

variable "bitbucket_oauth_client_id" {
  description = "Bitbucket OAuth app client ID used by tribal V8 generation to refresh tenant repo access tokens."
  type        = string
  default     = ""
}

variable "bitbucket_oauth_client_secret" {
  description = "Bitbucket OAuth app client secret used by tribal V8 generation to refresh tenant repo access tokens."
  type        = string
  sensitive   = true
  default     = ""
}

variable "openai_api_key" {
  description = "Per-tenant OpenAI API key, supplied by the `openai_api_key` apiParameter at instance create/modify. Plumbed through to api-gateway / intern / onboarding Helm via the pavoInfra.openai_api_key output."
  type        = string
  sensitive   = true
}

variable "e2b_api_key" {
  description = "E2B API key for sandbox-backed agent computer sessions."
  type        = string
  sensitive   = true
  default     = ""
}

variable "e2b_template_id" {
  description = "Default E2B template ID for agent computer sessions (non-GCS path)."
  type        = string
  default     = ""
}

variable "e2b_gcs_template_id" {
  description = "GCS-fuse capable E2B template ID used when sandbox GCS mount is enabled."
  type        = string
  default     = "pavo-gcsfuse-ml-viz"
}

variable "sandbox_gcsfuse_enabled" {
  description = "Enable GCS-fuse mount credentials for E2B sandboxes."
  type        = bool
  default     = false
}

variable "sandbox_gcsfuse_key_json" {
  description = "Service-account JSON used by E2B sandboxes to mount the intern data bucket with gcsfuse."
  type        = string
  sensitive   = true
  default     = ""
}

variable "exec_runner_hmac_required" {
  description = "Require HMAC signatures for calls into exec-runner."
  type        = bool
  default     = false
}

variable "task_agent_use_agent_computer_runtime" {
  description = "Legacy master toggle for agent-computer runtime; use \"1\" to enable."
  type        = string
  default     = ""
}

variable "pavo_computer_backend" {
  description = "Legacy computer backend selector (for example: e2b)."
  type        = string
  default     = ""
}

variable "worker_proxy_routing_enabled" {
  description = "Route sandbox worker egress through capability-proxy."
  type        = bool
  default     = false
}

# -----------------------------------------------------------------------------
# Identity runtime — pavoInfra pass-through inputs from pavo-customer-bootstrap
# -----------------------------------------------------------------------------
# 15 values. customer-bootstrap is the single source of truth; pavoInfra only
# passes them through to outputs (with base64encode as the one allowed
# transform). Do NOT add IdP/Zitadel computation logic here — push it to
# customer-bootstrap if it's missing. See README → "Ownership rules".
#
# Empty strings are legitimate values for the IdP / SAML fields (no-IdP and
# non-SAML customers). The 5 core Zitadel fields MUST be non-empty —
# the terraform_data validate block in main.tf enforces that.

variable "zitadel_org_id" {
  description = "Zitadel org ID (pass-through from pavo-customer-bootstrap)."
  type        = string
}

variable "zitadel_project_id" {
  description = "Zitadel project ID (pass-through from pavo-customer-bootstrap)."
  type        = string
}

variable "zitadel_oidc_client_id" {
  description = "Zitadel OIDC client ID (pass-through from pavo-customer-bootstrap)."
  type        = string
  sensitive   = true
}

variable "zitadel_oidc_client_secret" {
  description = "Zitadel OIDC client secret (pass-through from pavo-customer-bootstrap, Omnistrate type: Password)."
  type        = string
  sensitive   = true
}

variable "zitadel_issuer" {
  description = "Zitadel OIDC issuer URL (pass-through from pavo-customer-bootstrap)."
  type        = string
}

variable "zitadel_org_primary_domain" {
  description = "Customer-stable Zitadel org domain `<customer_name>.auth.pavoai.com` (pass-through from pavo-customer-bootstrap)."
  type        = string
}

variable "zitadel_idp_id" {
  description = "Zitadel OAuth IdP ID — google or oidc (NOT SAML; pass-through from pavo-customer-bootstrap). Empty for no-IdP or SAML customers. pavoInfra base64-encodes this for the frontend output."
  type        = string
  default     = ""
}

variable "primary_external_identity_provider_enabled" {
  description = "Whether the frontend should expose a 'Continue with X' button (pass-through from pavo-customer-bootstrap)."
  type        = bool
  default     = false
}

variable "primary_external_identity_provider_type" {
  description = "IdP type for the frontend — `google` / `okta` / `oidc` / `` (no IdP). Pass-through from pavo-customer-bootstrap; the source-of-truth value is normalized lowercase + trimmed inside customer-bootstrap, so by the time it reaches pavoInfra it must already be canonical."
  type        = string
  default     = ""

  validation {
    # Exact-match against canonical values (no lower()/trimspace() wrap on the
    # check). " Google " or "GOOGLE" coming in here means customer-bootstrap
    # leaked a non-canonical value into its output — fail loud at plan time
    # rather than ship a subtly-wrong frontend label downstream.
    condition = contains(
      ["", "google", "okta", "oidc"],
      var.primary_external_identity_provider_type,
    )
    error_message = "primary_external_identity_provider_type must be exactly one of: '', 'google', 'okta', 'oidc' (lowercase, no surrounding whitespace). customer-bootstrap should normalize before emitting."
  }
}

variable "primary_external_identity_provider_label" {
  description = "Frontend 'Continue with X' button text (pass-through from pavo-customer-bootstrap)."
  type        = string
  default     = ""
}

variable "primary_external_identity_provider_prompt" {
  description = "OAuth `prompt` query parameter (pass-through from pavo-customer-bootstrap)."
  type        = string
  default     = ""
}

variable "primary_external_identity_provider_saml_idp_id" {
  description = "Zitadel SAML IdP numeric ID (pass-through from pavo-customer-bootstrap). Empty for non-SAML customers."
  type        = string
  default     = ""
}

variable "primary_external_identity_provider_saml_sp_metadata_url" {
  description = "Zitadel SAML SP metadata URL (pass-through from pavo-customer-bootstrap). Empty for non-SAML customers."
  type        = string
  default     = ""
}

variable "primary_external_identity_provider_saml_sp_entity_id" {
  description = "Zitadel SAML SP EntityID (pass-through from pavo-customer-bootstrap). Empty for non-SAML customers."
  type        = string
  default     = ""
}

variable "primary_external_identity_provider_saml_acs_url" {
  description = "Zitadel SAML ACS URL (pass-through from pavo-customer-bootstrap). Empty for non-SAML customers."
  type        = string
  default     = ""
}

# -----------------------------------------------------------------------------
# Derived locals
# -----------------------------------------------------------------------------

locals {
  db_username = "pavo"

  # ---------------------------------------------------------------------------
  # AWS resource tags (FinOps cost allocation)
  # ---------------------------------------------------------------------------
  # Pavo standard set: present on every AWS resource regardless of customer.
  # Keys are snake_case for internal consistency (Cost Explorer is
  # case-sensitive — mixing PascalCase + lowercase would split tag groupings).
  # environment is hardcoded "prod": this module IS the prod AWS module. POC
  # vs. paid status is conveyed by customer-specific tags (e.g. service=...),
  # not by environment.
  # Canonical cross-cloud cost-allocation keys: customer / instance / environment
  # / managed_by (the same set the GCP and legacy modules emit). `instance`
  # replaces the former `omnistrate_instance` key (single-write; nothing else
  # consumes the old key). Team-level cost-center lives in dim_namespace_owner,
  # not here (per-customer infra has no single owning team).
  pavo_standard_tags = {
    managed_by  = "pavo"
    customer    = var.customer_name
    environment = "prod"
    instance    = var.instance_id
  }

  # Customer-specific cost-allocation keys (e.g. team, service, cost-center).
  # Sourced from customer-configuration.tf so per-customer FinOps schemas are
  # tracked in git and code-reviewed. Customers without an entry fall through
  # to {}.
  tenant_customer_configuration = lookup(
    lookup(local.customer_configuration, "customers", {}),
    var.customer_name,
    {},
  )
  tenant_customer_tags = lookup(local.tenant_customer_configuration, "tags", {})

  # Final merged tag set fed to provider "aws" default_tags.
  # Merge order: pavo_standard_tags goes LAST so it wins on key collision —
  # this prevents a customer entry from accidentally redefining
  # managed_by / customer / environment / instance and corrupting
  # Pavo's own cost reporting. Customer keys supplement only.
  #
  # IMPORTANT: AWS provider default_tags can ALSO be overridden by
  # resource-level tags = {} blocks in main.tf with the same key. Do NOT
  # add managed_by / customer / environment / instance at the
  # resource level unless deliberately overriding for a specific resource.
  # The per-resource Name tag is fine (and intentional) — Name is unique
  # per resource and doesn't collide with this set.
  aws_default_tags = merge(local.tenant_customer_tags, local.pavo_standard_tags)
}

# Teardown controls — see README "Teardown contract" section.
# These exist so terraform destroy can run cleanly on instance delete without
# state surgery. Defaults are safe for Prod; flip via Omnistrate instance modify
# before issuing instance delete on Dev/test (or to consciously override the
# data-loss guard on Prod). Note: rds_deletion_protection is defined earlier in
# this file alongside the other RDS settings.
# -----------------------------------------------------------------------------

variable "create_final_snapshot" {
  description = "Whether the RDS instance takes a final snapshot on destroy. For Dev/test recreate cycles, set false to avoid orphan snapshots."
  type        = bool
  default     = true
}

variable "force_destroy_buckets" {
  description = "Whether terraform destroy empties non-empty S3 buckets. Default false: destroy errors on non-empty bucket (safe behavior). Set true for Dev/test instances where bucket contents are disposable."
  type        = bool
  default     = false
}
