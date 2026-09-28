# -----------------------------------------------------------------------------
# Terraform Outputs — AWS module
# -----------------------------------------------------------------------------
# These outputs become available as $out.pavoInfra.* in the Omnistrate spec.
# Output names mirror the GCP module where possible for symmetric spec wiring.
# -----------------------------------------------------------------------------

# -----------------------------------------------------------------------------
# Database
# -----------------------------------------------------------------------------

output "rds_endpoint" {
  description = "RDS hostname for direct connection (port is always 5432, injected separately via db.port)"
  value       = aws_db_instance.postgres.address
}

output "gateway_db_name" {
  description = "Gateway database name"
  value       = "pavo-gateway-db"
}

output "intern_db_name" {
  description = "Intern database name"
  value       = "pavo-intern-db"
}

output "onboarding_db_name" {
  description = "Onboarding database name"
  value       = "pavo-onboarding-db"
}

output "knm_db_name" {
  description = "KNM (tribal knowledge) database name"
  value       = "pavo-knm-db"
}

output "db_username" {
  description = "Database username"
  value       = local.db_username
}

output "db_secret_arn" {
  description = "ARN of the RDS-managed master user password secret in AWS Secrets Manager."
  value       = aws_db_instance.postgres.master_user_secret[0].secret_arn
}

output "eso_role_arn" {
  description = "DEPRECATED — kept as an empty placeholder so any consumer that still references $pavoInfra.out.eso_role_arn doesn't break. ESO is now owned by pavo-bootstrap-aws (cell-scoped); the role ARN is no longer a per-instance pavoInfra output. Remove this entirely once nothing references it. Tracked as a follow-up."
  value       = ""
  sensitive   = true
}

# -----------------------------------------------------------------------------
# Redis
# -----------------------------------------------------------------------------

output "gateway_redis_host_ip" {
  description = "Gateway Redis primary endpoint"
  value       = aws_elasticache_replication_group.gateway.primary_endpoint_address
}

output "gateway_redis_url" {
  description = "Gateway Redis URL"
  value       = "redis://${aws_elasticache_replication_group.gateway.primary_endpoint_address}:6379/0"
}

output "intern_redis_host_ip" {
  description = "Intern Redis primary endpoint"
  value       = aws_elasticache_replication_group.intern.primary_endpoint_address
}

output "intern_redis_url" {
  description = "Intern Redis URL"
  value       = "redis://${aws_elasticache_replication_group.intern.primary_endpoint_address}:6379/0"
}

output "onboarding_redis_host_ip" {
  description = "Onboarding Redis primary endpoint"
  value       = aws_elasticache_replication_group.onboarding.primary_endpoint_address
}

# -----------------------------------------------------------------------------
# Storage (S3)
# -----------------------------------------------------------------------------

output "onboarding_bucket_name" {
  description = "Onboarding S3 bucket name (replaces gcs_bucket_name)"
  value       = aws_s3_bucket.onboarding.bucket
}

output "intern_data_bucket_name" {
  description = "Intern data S3 bucket name"
  value       = aws_s3_bucket.intern_data.bucket
}

# -----------------------------------------------------------------------------
# Messaging — main queues/topics
# -----------------------------------------------------------------------------

output "publisher_topic_arn" {
  description = "SNS data-fetcher topic ARN (replaces pubsub_topic_name)"
  value       = aws_sns_topic.data_fetcher.arn
}

output "publisher_dedup_topic_arn" {
  description = "SNS dedup topic ARN (replaces pubsub_deduplicated_topic_name)"
  value       = aws_sns_topic.dedup.arn
}

output "connector_sync_topic_arn" {
  description = "connector_sync SNS topic ARN; orchestrator publishes here, each connector worker consumes its per-type filtered SQS queue (pavo-connector-sync-<type>-sub-<instance>)"
  value       = aws_sns_topic.connector_sync.arn
}

output "orchestrator_subscription_url" {
  description = "SQS orchestrator queue URL (replaces orchestrator_subscription_name)"
  value       = aws_sqs_queue.orch.url
}

output "nugget_subscription_url" {
  description = "SQS nugget queue URL (replaces nugget_subscription_name)"
  value       = aws_sqs_queue.nugget.url
}

output "rag_subscription_url" {
  description = "SQS RAG queue URL (replaces rag_subscription_name)"
  value       = aws_sqs_queue.rag.url
}

# -----------------------------------------------------------------------------
# Messaging — DLQs (SQS queue URLs, not SNS ARNs)
# -----------------------------------------------------------------------------

output "orchestrator_dlq_subscription_url" {
  description = "SQS orchestrator DLQ URL (replaces orchestrator_dlq_subscription_name)"
  value       = aws_sqs_queue.orch_dlq.url
}

output "nugget_dlq_subscription_url" {
  description = "SQS nugget DLQ URL (replaces nugget_dlq_subscription_name)"
  value       = aws_sqs_queue.nugget_dlq.url
}

output "rag_dlq_subscription_url" {
  description = "SQS RAG DLQ URL (replaces rag_dlq_subscription_name)"
  value       = aws_sqs_queue.rag_dlq.url
}

# -----------------------------------------------------------------------------
# IAM (IRSA)
# -----------------------------------------------------------------------------

output "aws_iam_role_arn" {
  description = "IAM role ARN for IRSA (replaces gcp_service_account_email)"
  value       = aws_iam_role.pavo.arn
}

# -----------------------------------------------------------------------------
# Cloud identity / region
# -----------------------------------------------------------------------------

output "aws_region" {
  description = "AWS region"
  value       = var.aws_region
}

output "aws_account_id" {
  description = "AWS account ID"
  value       = data.aws_caller_identity.current.account_id
}

output "customer_name" {
  description = "Customer name"
  value       = var.customer_name
}

output "app_domain" {
  description = "Public domain the app is served on (frontend host; API served at api.<app_domain>). Derives <customer_name>.<base_domain> when app_domain is unset."
  value       = local.app_domain
}

# -----------------------------------------------------------------------------
# Elasticsearch (cloud-agnostic — same output names as GCP)
# -----------------------------------------------------------------------------

output "elasticsearch_endpoint" {
  description = "Elasticsearch HTTPS endpoint URL"
  value = var.es_mode == "self_hosted" ? (
    "https://${local.es_name}-es-http.${var.instance_id}.svc:9200"
  ) : one(ec_deployment.onboarding_es[*].elasticsearch.https_endpoint)
}

output "elasticsearch_cloud_id" {
  description = "Elasticsearch Cloud ID (empty on self_hosted)"
  value       = var.es_mode == "self_hosted" ? "" : one(ec_deployment.onboarding_es[*].elasticsearch.cloud_id)
}

output "elasticsearch_api_key" {
  description = "Elasticsearch API key (id:key format; empty on self_hosted)"
  value = (
    var.es_mode == "self_hosted" ? "" :
    var.elasticsearch_api_key != "" ? var.elasticsearch_api_key :
    "${one(elasticstack_elasticsearch_security_api_key.app_api_key[*].key_id)}:${one(elasticstack_elasticsearch_security_api_key.app_api_key[*].api_key)}"
  )
  sensitive = true
}

# Self-hosted only (empty on cloud): the ECK-generated HTTP CA secret + the app
# fileRealm user secret, consumed by the app pods (see spec-byoc.yaml wiring).
output "elasticsearch_ca_cert_secret_name" {
  description = "Name of the ECK HTTP CA secret (self_hosted only; key ca.crt)"
  value       = var.es_mode == "self_hosted" ? "${local.es_name}-es-http-certs-public" : ""
}

output "elasticsearch_app_user_secret_name" {
  description = "Name of the app fileRealm user secret (self_hosted only; keys username/password/roles)"
  value       = var.es_mode == "self_hosted" ? "es-app-user" : ""
}

# Observability routing mode — apps read this to send metrics to Grafana Cloud
# (cloud) or the in-VPC observability stack (self_hosted). No per-instance TF
# resources: the in-VPC stack is cell-scoped, provisioned by pavo-bootstrap-aws
# (var.enable_observability), so this just echoes the flag.
output "grafana_mode" {
  description = "cloud | self_hosted — apps switch their telemetry routing on this."
  value       = var.grafana_mode
}

# -----------------------------------------------------------------------------
# In-VPC self-hosted Zitadel (zitadel_mode=self_hosted) — the Terraform-KNOWN
# config the spec/Helm injects into api-gateway + frontend. The born-in-cluster
# identity (client id/secret, org/idp ids) is NOT here — the Provision Job's
# handoff objects (below) carry it. All empty/cloud on the default path.
# -----------------------------------------------------------------------------
output "zitadel_mode" {
  description = "cloud | self_hosted — apps switch their auth wiring on this."
  value       = var.zitadel_mode
}

output "email_enabled" {
  description = "api-gateway EMAIL_ENABLED. Empty var derives the posture-aware default (off for self_hosted/IdP-only, on for cloud) — matching the old enable_email_login behavior; an explicit \"true\"/\"false\" overrides."
  value       = tostring(local.email_enabled)
}

output "email_backend" {
  description = "api-gateway EMAIL_BACKEND. AWS instances always send via SES (over the SES VPC endpoint in strict cells)."
  value       = "ses"
}

output "email_from" {
  description = "api-gateway EMAIL_FROM. Derived from the instance's app_domain; must be DKIM-verified in SES (see ses_dkim_tokens)."
  value       = "noreply@${local.app_domain}"
}

output "email_region" {
  description = "api-gateway EMAIL_REGION — the AWS region SES sends from."
  value       = var.aws_region
}

output "zitadel_backend_secret_name" {
  description = "K8s secret the Provision Job writes for api-gateway (self_hosted only; empty on cloud)."
  value       = local.zitadel_self_hosted ? local.zitadel_backend_secret : ""
}

output "zitadel_frontend_config_name" {
  description = "K8s configmap the Provision Job writes for the frontend (self_hosted only; empty on cloud)."
  value       = local.zitadel_self_hosted ? local.zitadel_frontend_config : ""
}

output "zitadel_self_hosted_issuer" {
  description = "Public issuer for the in-VPC Zitadel — api-gateway ZITADEL_ISSUER (self_hosted only; empty on cloud so the gateway falls back to ZITADEL_DOMAIN)."
  value       = local.zitadel_self_hosted ? "https://${local.zitadel_auth_host}" : ""
}

output "zitadel_frontend_authority" {
  description = "Frontend VITE_ZITADEL_AUTHORITY — the in-VPC issuer on self_hosted, the central auth.pavoai.com on cloud (mode-aware so cloud is unchanged)."
  value       = local.zitadel_self_hosted ? "https://${local.zitadel_auth_host}" : "https://auth.pavoai.com"
}

output "zitadel_internal_base_url" {
  description = "Internal svc api-gateway calls for token/jwks/userinfo (self_hosted only)."
  value       = local.zitadel_self_hosted ? local.zitadel_internal_url : ""
}

output "zitadel_internal_host_header" {
  description = "Host header for api-gateway's internal-transport calls (self_hosted only)."
  value       = local.zitadel_self_hosted ? local.zitadel_auth_host : ""
}

output "zitadel_oidc_redirect_uri" {
  description = "Frontend OIDC callback (VITE_OIDC_REDIRECT_URI) on the app host (self_hosted only)."
  value       = local.zitadel_self_hosted ? "https://${local.app_domain}/login/oidc-callback" : ""
}

# -----------------------------------------------------------------------------
# Self-hosted Temporal (temporal_mode=self_hosted): in-cluster endpoint + the
# cert-manager client-cert secret intern mounts. Empty on cloud — the intern
# chart prefers these when non-empty and otherwise keeps the gdv7k Temporal
# Cloud values from the spec (same guard pattern as elasticsearch_*).
# -----------------------------------------------------------------------------

output "temporal_mode" {
  description = "Echo of temporal_mode so app charts can gate on it."
  value       = var.temporal_mode
}

output "temporal_host" {
  description = "In-cluster Temporal frontend host (self_hosted only; matches the frontend cert SAN so clients need no server-name override)."
  value       = local.temporal_self_hosted ? local.temporal_frontend_host : ""
}

output "temporal_namespace" {
  description = "Temporal (logical) namespace registered for intern (self_hosted only)."
  value       = local.temporal_self_hosted ? local.temporal_namespace : ""
}

output "temporal_client_cert_secret_name" {
  description = "cert-manager Secret (tls.crt/tls.key/ca.crt) holding intern's Temporal mTLS client identity (self_hosted only)."
  value       = local.temporal_self_hosted ? local.temporal_intern_cert_secret : ""
}

# -----------------------------------------------------------------------------
# Kubernetes
# -----------------------------------------------------------------------------

output "efs_storage_class_name" {
  description = "EFS StorageClass name for RWX PVCs (replaces filestore_storage_class_name)"
  value       = kubernetes_storage_class_v1.efs_pavo.metadata[0].name
}

# -----------------------------------------------------------------------------
# VAPID (Web Push — same output names for both clouds)
# -----------------------------------------------------------------------------

output "vapid_public_key" {
  description = "VAPID public key (PEM) delivered to frontend"
  value       = tls_private_key.vapid.public_key_pem
}

output "vapid_private_key" {
  description = "VAPID private key (PEM) used by intern backend"
  value       = tls_private_key.vapid.private_key_pem
  sensitive   = true
}

output "vapid_contact_email" {
  description = "VAPID contact email (mailto: URI)"
  value       = "mailto:admin@pavoai.com"
}

# -----------------------------------------------------------------------------
# Auto-generated Secrets (same names as GCP)
# -----------------------------------------------------------------------------

output "capability_token_secret" {
  description = "Auto-generated capability token signing secret"
  value       = random_password.capability_token_secret.result
  sensitive   = true
}

output "worker_api_secret" {
  description = "Auto-generated worker API authentication secret"
  value       = random_password.worker_api_secret.result
  sensitive   = true
}

# -----------------------------------------------------------------------------
# Pass-through Secrets
# -----------------------------------------------------------------------------

output "modal_token_id" {
  description = "Modal cloud compute token ID"
  value       = var.modal_token_id
  sensitive   = true
}

output "modal_token_secret" {
  description = "Modal cloud compute token secret"
  value       = var.modal_token_secret
  sensitive   = true
}

output "parallel_api_key" {
  description = "Per-tenant Parallel web search API key"
  value       = trimspace(var.parallel_api_key)
  sensitive   = true
}

output "amplitude_api_key" {
  description = "Per-tenant Amplitude analytics API key"
  value       = trimspace(var.amplitude_api_key)
  sensitive   = true
}

output "sumble_api_key" {
  description = "Per-tenant Sumble company-enrichment API key"
  value       = trimspace(var.sumble_api_key)
  sensitive   = true
}

# -----------------------------------------------------------------------------
# api-gateway 3P Outputs: HubSpot / Brevo / Langfuse
# -----------------------------------------------------------------------------

output "hubspot_api_key" {
  description = "HubSpot API key for api-gateway (per-tenant override wins over the environment-level secret)"
  value       = trimspace(var.hubspot_api_key_override) != "" ? trimspace(var.hubspot_api_key_override) : var.hubspot_api_key
  sensitive   = true
}

output "hubspot_client_secret" {
  description = "HubSpot client secret for api-gateway webhook verification (per-tenant override wins over the environment-level secret)"
  value       = trimspace(var.hubspot_client_secret_override) != "" ? trimspace(var.hubspot_client_secret_override) : var.hubspot_client_secret
  sensitive   = true
}

output "brevo_api_key" {
  description = "Per-tenant Brevo API key for api-gateway transactional email"
  value       = trimspace(var.brevo_api_key)
  sensitive   = true
}

output "hubspot_enabled" {
  description = "Per-customer HubSpot kill switch for api-gateway"
  value       = var.hubspot_enabled
}

output "langfuse_enabled" {
  description = "Per-customer Langfuse tracing kill switch for api-gateway"
  value       = var.langfuse_enabled
}

output "langfuse_public_key" {
  description = "Per-tenant Langfuse public key for api-gateway"
  value       = trimspace(var.langfuse_public_key)
  sensitive   = true
}

output "langfuse_secret_key" {
  description = "Per-tenant Langfuse secret key for api-gateway"
  value       = trimspace(var.langfuse_secret_key)
  sensitive   = true
}

output "langfuse_host" {
  description = "Langfuse host for api-gateway"
  value       = var.langfuse_host
}

output "temporal_payload_codec_key" {
  description = "Temporal payload codec encryption key"
  value       = var.temporal_payload_codec_key
  sensitive   = true
}

output "gemini_api_key" {
  description = "Google Gemini API key"
  value       = var.gemini_api_key
  sensitive   = true
}

output "openai_api_key" {
  description = "OpenAI API key"
  value       = trimspace(var.openai_api_key)
  sensitive   = true
}

output "anthropic_api_key" {
  description = "Anthropic API key for tribal V8 book generation"
  value       = trimspace(var.anthropic_api_key)
  sensitive   = true
}

output "e2b_api_key" {
  description = "E2B API key for sandbox-backed agent computer sessions"
  value       = trimspace(var.e2b_api_key)
  sensitive   = true
}

output "e2b_template_id" {
  description = "Default E2B template ID for agent computer sessions (non-GCS path)"
  value       = trimspace(var.e2b_template_id)
}

output "e2b_gcs_template_id" {
  description = "GCS-fuse capable E2B template ID used when sandbox GCS mount is enabled"
  value       = trimspace(var.e2b_gcs_template_id)
}

output "sandbox_gcsfuse_enabled" {
  description = "Enable GCS-fuse mount credentials for E2B sandboxes"
  value       = tostring(var.sandbox_gcsfuse_enabled)
}

output "sandbox_gcsfuse_key_json" {
  description = "Service-account JSON used by E2B sandboxes to mount the intern data bucket with gcsfuse"
  value       = var.sandbox_gcsfuse_key_json
  sensitive   = true
}

output "exec_runner_hmac_required" {
  description = "Require HMAC signatures for calls into exec-runner"
  value       = tostring(var.exec_runner_hmac_required)
}

output "task_agent_use_agent_computer_runtime" {
  description = "Legacy master toggle for agent-computer runtime"
  value       = trimspace(var.task_agent_use_agent_computer_runtime)
}

output "pavo_computer_backend" {
  description = "Legacy computer backend selector"
  value       = trimspace(var.pavo_computer_backend)
}

output "worker_proxy_routing_enabled" {
  description = "Route sandbox worker egress through capability-proxy"
  value       = tostring(var.worker_proxy_routing_enabled)
}

output "bitbucket_oauth_client_id" {
  description = "Bitbucket OAuth app client ID for tribal V8 book generation"
  value       = var.bitbucket_oauth_client_id
}

output "bitbucket_oauth_client_secret" {
  description = "Bitbucket OAuth app client secret for tribal V8 book generation"
  value       = var.bitbucket_oauth_client_secret
  sensitive   = true
}

# -----------------------------------------------------------------------------
# ZITADEL Outputs (per-customer OIDC credentials)
# -----------------------------------------------------------------------------

# -----------------------------------------------------------------------------
# Identity runtime outputs — pavoInfra is a pure pass-through.
# -----------------------------------------------------------------------------
# customer-bootstrap owns identity computation; these outputs pass values
# straight from var.* to spec consumers (api-gateway / frontend), with
# base64encode as the only allowed transform (pure function — no identity
# semantics here). If you find yourself adding identity logic to this file,
# stop — push it to pavo-customer-bootstrap and add a new pass-through var.

# zitadel_client_id (plaintext) intentionally NOT exported: the 18-digit (>2^53)
# id float-coerces through the Omnistrate value pipeline. Consumers use the
# base64 form below and decode it. See spec-byoc.yaml api-gateway wiring.
output "zitadel_client_id_base64" {
  description = "Base64-encoded zitadel_client_id for gateway/frontend consumption (float-safe transport)."
  value       = base64encode(var.zitadel_oidc_client_id)
  sensitive   = true
}

output "zitadel_client_secret" {
  description = "Zitadel OIDC client secret (pass-through from var.zitadel_oidc_client_secret)."
  value       = var.zitadel_oidc_client_secret
  sensitive   = true
}

output "zitadel_org_id" {
  description = "Zitadel organization ID (pass-through from var.zitadel_org_id)."
  value       = var.zitadel_org_id
}

output "zitadel_org_id_base64" {
  description = "Base64-encoded zitadel_org_id for frontend consumption."
  value       = base64encode(var.zitadel_org_id)
}

output "zitadel_idp_id_base64" {
  description = "Base64-encoded Zitadel primary external (OAuth) IdP ID — empty when no OAuth IdP is configured."
  value       = base64encode(var.zitadel_idp_id)
}

output "zitadel_org_primary_domain" {
  description = "Zitadel organization primary domain (pass-through from var.zitadel_org_primary_domain)."
  value       = var.zitadel_org_primary_domain
}

output "primary_external_identity_provider_enabled" {
  description = "Whether the frontend should expose a 'Continue with X' button (pass-through)."
  value       = tostring(var.primary_external_identity_provider_enabled)
}

output "primary_external_identity_provider_type" {
  description = "IdP type for the frontend (pass-through)."
  value       = var.primary_external_identity_provider_type
}

output "primary_external_identity_provider_label" {
  description = "Frontend 'Continue with X' button text (pass-through)."
  value       = var.primary_external_identity_provider_label
}

output "primary_external_identity_provider_prompt" {
  description = "OAuth `prompt` query parameter (pass-through)."
  value       = var.primary_external_identity_provider_prompt
}

output "primary_external_identity_provider_saml_idp_id" {
  description = "Zitadel SAML IdP numeric ID (pass-through). Empty for non-SAML customers."
  value       = var.primary_external_identity_provider_saml_idp_id
}

output "primary_external_identity_provider_saml_sp_metadata_url" {
  description = "Zitadel SAML SP metadata URL (pass-through). Empty for non-SAML customers."
  value       = var.primary_external_identity_provider_saml_sp_metadata_url
}

output "primary_external_identity_provider_saml_sp_entity_id" {
  description = "Zitadel SAML SP EntityID (pass-through). Empty for non-SAML customers."
  value       = var.primary_external_identity_provider_saml_sp_entity_id
}

output "primary_external_identity_provider_saml_acs_url" {
  description = "Zitadel SAML ACS URL (pass-through). Empty for non-SAML customers."
  value       = var.primary_external_identity_provider_saml_acs_url
}
