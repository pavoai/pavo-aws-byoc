# Inputs contract: `terraform-omnistrate-aws`

Generated from Pavo's Omnistrate service definition and this module's variable
declarations. It lists every input of the module and where its value comes
from when Omnistrate runs it. 99 variables in total.

## Instance parameters

Set per instance through Omnistrate (by Pavo, or by the customer where the
product exposes them).

| Variable | Parameter | Type | Required | Modifiable after create | Description |
|---|---|---|---|---|---|
| `amplitude_api_key` | `amplitude_api_key` | Password | no | yes | Amplitude analytics API key for this tenant. Per-customer; set at instance create and rotate via instance modify. Empty disables Amplitude tracking in intern. |
| `anthropic_api_key` | `anthropic_api_key` | Password | yes | yes | Anthropic API key for this tenant (used by tribal V8 book generation fallback/sub-generators). Per-customer; set at instance create and rotate via instance modify. The snake_case key is the canonical name — do NOT pass `anthropicApiKey` (camelCase) on modify, Omnistrate accepts unknown keys silently and the snake_case slot stays empty. |
| `app_domain` | `app_domain` | String | no | yes | Public domain the app is served on: frontend at https://<app_domain>, API at https://api.<app_domain>. Empty auto-derives <customer_name>.<base_domain> (e.g. <customer>.pavoai.dev). Set to serve a custom domain, e.g. app.pavoai.com for the multi-tenant prod instance. |
| `auth_hostname` | `auth_hostname` | String | no | yes | Public hostname for the in-VPC Zitadel (zitadel_mode=self_hosted only). Empty auto-derives auth.<customer_name>.<base_domain>. Set to bring your own domain. |
| `aws_microvm_image_arn` | `aws_microvm_image_arn` | String | no | yes | Existing-image override. Supply ARN, region and matching secret together; mutually exclusive with managed image mode. |
| `aws_microvm_image_revision` | `aws_microvm_image_revision` | String | no | yes | Immutable release identifier for managed MicroVM image publication. Changing this creates a new image/secret pair; preserve old task routing and validate before switching. |
| `aws_microvm_managed_image_enabled` | `aws_microvm_managed_image_enabled` | Boolean | no | yes | AWS only. Build an immutable customer-owned MicroVM image using a signed publisher Job. Requires the opt-in MicroVM build boundaries from customer bootstrap. Keep all existing-image override fields empty in managed mode; enabling image creation does not change task routing. |
| `aws_microvm_publisher_image` | `aws_microvm_publisher_image` | String | no | yes | Digest-pinned signed ghcr.io/pavoai/microvm-publisher image. Required for managed mode; publisher/context changes require a new release and validation. |
| `aws_microvm_region` | `aws_microvm_region` | String | no | yes | Existing-image override. Supply ARN, region and matching secret together; mutually exclusive with managed image mode. |
| `aws_microvm_worker_secret` | `aws_microvm_worker_secret` | Password | no | yes | Existing-image override. Supply ARN, region and matching secret together; mutually exclusive with managed image mode. |
| `brevo_api_key` | `brevo_api_key` | Password | no | yes | Brevo transactional-email API key for this tenant. Per-customer; set at instance create and rotate via instance modify. Empty disables Brevo email in api-gateway. |
| `cell_kms_key_arn` | `cell_kms_key_arn` | String | yes | no | ARN of your single customer-managed KMS key. Encrypts everything this deployment stores at rest under your own key: RDS storage + master-password secret, ElastiCache Redis, SNS topics, EFS, self-hosted Elasticsearch EBS + snapshots, Zitadel, and the in-VPC observability volumes. One key for the whole deployment. (Renamed from db_kms_key_arn — BREAKING: existing instances must set cell_kms_key_arn… |
| `create_final_snapshot` | `create_final_snapshot` | Boolean | no | yes | Whether the RDS instance takes a final snapshot on destroy. Set false for Dev/test recreate cycles to avoid orphan snapshots. |
| `customer_name` | `customer_name` | String | yes | no | Customer identifier (used for resource naming) |
| `e2b_api_key` | `e2b_api_key` | Password | no | yes | E2B API key for sandbox-backed agent computer sessions. |
| `e2b_gcs_template_id` | `e2b_gcs_template_id` | String | no | yes | GCS-fuse capable E2B template ID used when sandbox GCS mount is enabled. |
| `e2b_template_id` | `e2b_template_id` | String | no | yes | Default E2B template ID for agent computer sessions (non-GCS path). Empty keeps runtime defaults. |
| `efs_iam_auth_enforced` | `efs_iam_auth_enforced` | Boolean | no | no | EFS mounts must be IAM-signed by the CSI node role (StorageClass gets the iam mount option). Set at creation only (not modifiable): flipping an existing instance would deny its already-bound PVs, which mount anonymously, on next remount. Create new instances with true. AWS BYOC only; unused on GCP. |
| `elastic_cloud_region` | `elastic_cloud_region` | String | yes | no | Elastic Cloud region for the ES deployment (e.g. us-east-2). |
| `email_enabled` | `email_enabled` | String | no | yes | Master switch for this instance's email path (login + all notifications). 'true' = email on (SES on AWS, Brevo on GCP); 'false' = strict/air-gapped (no backend wired, OTP endpoints 403, invitations return a copyable link). Empty (default) derives the POSTURE-AWARE default, preserving the old enable_email_login behavior: off for self_hosted/IdP-only instances, on for cloud. Replaces enable_email_l… |
| `enable_lambda_microvms` | `enable_lambda_microvms` | Boolean | no | yes | DEPRECATED - has no effect. The Lambda MicroVM IAM grants are now rendered unconditionally on every AWS cell. Gating them on this per-instance parameter took the grants offline for 28-79 minutes on every deploy: an early deploy phase renders Terraform without the instance parameters, so the gate evaluated false and the workload role's policy was re-applied without the MicroVM statements. This par… |
| `es_mode` | `es_mode` | String | no | yes | Elasticsearch backend for this instance: 'cloud' (default — external Elastic Cloud, unchanged behavior) or 'self_hosted' (in-VPC Elasticsearch via ECK, EBS under the customer CMK, snapshots to a customer S3 bucket). AWS BYOC only; unused on GCP. Modifiable post-create, but switching backends is operator-gated (ES snapshot/restore) — there is no automatic data migration. Observability backend is c… |
| `exec_runner_hmac_required` | `exec_runner_hmac_required` | Boolean | no | yes | Require HMAC signatures for calls into exec-runner. |
| `force_destroy_buckets` | `force_destroy_buckets` | Boolean | no | yes | Whether terraform destroy empties non-empty S3 / GCS buckets. Default false (destroy errors on non-empty bucket — the safe behavior). Set true for Dev/test instances where bucket contents are disposable. Applies to both AWS and GCP modules. |
| `grafana_mode` | `grafana_mode` | String | no | yes | Observability (metrics/Grafana) backend for this instance: 'cloud' (default — telemetry egresses to Grafana Cloud) or 'self_hosted' — this instance's metrics are collected by the in-VPC observability stack (in-VPC Prometheus scrapes each app's /metrics endpoint; Grafana + Prometheus run in-cluster), with no metrics egress to Grafana Cloud. Separate from es_mode so observability can be flipped ind… |
| `hubspot_api_key_override` | `hubspot_api_key` | Password | no | yes | Optional per-tenant override for the HubSpot API key used by api-gateway. When empty, the environment-level hubspot_api_key secret is used. |
| `hubspot_client_secret_override` | `hubspot_client_secret` | Password | no | yes | Optional per-tenant override for the HubSpot client secret used by api-gateway webhook verification. When empty, the environment-level hubspot_client_secret secret is used. |
| `hubspot_enabled` | `hubspot_enabled` | Boolean | no | yes | Per-customer kill switch for the HubSpot integration in api-gateway. When false (default), contact upserts on signup/login and the /hubspot/event webhook are short-circuited so no customer PII is sent to HubSpot. |
| `langfuse_enabled` | `langfuse_enabled` | Boolean | no | yes | Per-customer kill switch for Langfuse LLM tracing in api-gateway. When false (default), the Langfuse SDK is hard-disabled and no prompts/completions are exported. |
| `langfuse_host` | `langfuse_host` | String | no | yes | Langfuse host for api-gateway LLM tracing (supports self-hosted/EU instances). |
| `langfuse_public_key` | `langfuse_public_key` | Password | no | yes | Per-tenant Langfuse public key for api-gateway LLM tracing. Only used when langfuse_enabled is true. |
| `langfuse_secret_key` | `langfuse_secret_key` | Password | no | yes | Per-tenant Langfuse secret key for api-gateway LLM tracing. Only used when langfuse_enabled is true. |
| `network_posture` | `network_posture` | String | no | no | Network egress posture for this instance: 'standard' (default — public registry/LB egress allowed, Pavo-managed dependencies) or 'strict' (dedicated zero-egress cell). Umbrella for always-together strict network controls (provider mirror, internal LB, default-deny NetworkPolicy, private CA). On strict, OpenTofu requires es_mode / grafana_mode / temporal_mode / zitadel_mode = self_hosted at CREATE… |
| `openai_api_key` | `openai_api_key` | Password | yes | yes | OpenAI API key for this tenant. Per-customer; set at instance create and rotate via instance modify. The snake_case key is the canonical name — do NOT pass `openaiApiKey` (camelCase) on modify, Omnistrate accepts unknown keys silently and the snake_case slot stays empty. |
| `parallel_api_key` | `parallel_api_key` | Password | no | yes | Parallel web-search API key for this tenant. Per-customer; set at instance create and rotate via instance modify. Empty disables Parallel web search in intern. |
| `pavo_computer_backend` | `pavo_computer_backend` | String | no | yes | Legacy computer backend selector (for example: e2b). |
| `primary_external_identity_provider_automation_enabled` | `primary_external_identity_provider_automation_enabled` | Boolean | no | yes | self_hosted only: provision the customer IdP + IdP-only login policy in-VPC. Requires the client_id/secret (+ oidc_issuer or saml_metadata_url or saml_metadata_xml_base64) below. |
| `primary_external_identity_provider_client_id` | `primary_external_identity_provider_client_id` | String | no | yes | Client identifier for this tenant's primary external identity provider. |
| `primary_external_identity_provider_client_secret` | `primary_external_identity_provider_client_secret` | Password | no | yes | Client secret for this tenant's primary external identity provider. |
| `primary_external_identity_provider_enabled` | `primary_external_identity_provider_enabled` | Boolean | yes | no | Pavo-internal. Whether the frontend should show the 'Continue with X' button. Produced by pavo-customer-bootstrap. |
| `primary_external_identity_provider_label` | `primary_external_identity_provider_label` | String | no | yes | Frontend button text ('Continue with X'). Cloud: produced by pavo-customer-bootstrap. self_hosted: instance-modifiable input forwarded to in-VPC identity provisioning and re-exported to the frontend. |
| `primary_external_identity_provider_oidc_issuer` | `primary_external_identity_provider_oidc_issuer` | String | no | yes | self_hosted only: customer IdP OIDC issuer URL. Mutually exclusive with SAML metadata (URL or XML). |
| `primary_external_identity_provider_prompt` | `primary_external_identity_provider_prompt` | String | no | no | Pavo-internal. OAuth `prompt` query param (e.g. `select_account` for google). Produced by pavo-customer-bootstrap. |
| `primary_external_identity_provider_saml_acs_url` | `primary_external_identity_provider_saml_acs_url` | String | no | no | Pavo-internal. Zitadel SAML ACS URL. Empty for non-SAML. Produced by pavo-customer-bootstrap. |
| `primary_external_identity_provider_saml_attribute_names` | `primary_external_identity_provider_saml_attribute_names` | String | no | yes | self_hosted only: optional SAML attribute-name overrides for profile prefill, as first_name=<attr>,last_name=<attr>,email=<attr> (any subset). A set field uses only that exact name; unset fields use the defaults (givenname/surname/emailaddress, Microsoft claim URIs, urn:oid). |
| `primary_external_identity_provider_saml_idp_id` | `primary_external_identity_provider_saml_idp_id` | String | no | no | Pavo-internal. Zitadel SAML IdP numeric ID. Empty for non-SAML customers. Produced by pavo-customer-bootstrap. |
| `primary_external_identity_provider_saml_metadata_url` | `primary_external_identity_provider_saml_metadata_url` | String | no | yes | self_hosted only: customer IdP SAML metadata URL. Use when the metadata is reachable from the in-cluster provision job. Mutually exclusive with the OIDC issuer and SAML metadata XML. |
| `primary_external_identity_provider_saml_metadata_xml_base64` | `primary_external_identity_provider_saml_metadata_xml_base64` | String | no | yes | self_hosted only: base64-encoded customer IdP SAML metadata XML. Use when the provisioning environment cannot fetch a public metadata URL. Quotes and newlines survive Terraform variable rendering. Mutually exclusive with the OIDC issuer and SAML metadata URL. Customers may update this after instance creation. |
| `primary_external_identity_provider_saml_sp_entity_id` | `primary_external_identity_provider_saml_sp_entity_id` | String | no | no | Pavo-internal. Zitadel SAML SP EntityID (identical to metadata URL today). Empty for non-SAML. Produced by pavo-customer-bootstrap. |
| `primary_external_identity_provider_saml_sp_metadata_url` | `primary_external_identity_provider_saml_sp_metadata_url` | String | no | no | Pavo-internal. Zitadel SAML SP metadata URL. Empty for non-SAML. Produced by pavo-customer-bootstrap. |
| `primary_external_identity_provider_type` | `primary_external_identity_provider_type` | String | no | yes | IdP type (google / okta / oidc). Empty for no-IdP customers. Cloud: produced by pavo-customer-bootstrap. self_hosted: instance-modifiable input forwarded to in-VPC identity provisioning and re-exported to the frontend. |
| `rds_deletion_protection` | `rds_deletion_protection` | Boolean | no | yes | AWS-native deletion protection on the RDS instance. The intentional override that allows terraform destroy to remove the database; set false before issuing instance delete on Dev/test recreate cycles. |
| `redis_security_phase` | `redis_security_phase` | String | no | yes | ElastiCache TLS + AUTH rollout. AWS forbids skipping steps on an existing instance, so modify one step at a time and verify between: off (default, plaintext, no token) -> tls_preferred (TLS on, pods move to rediss://) -> tls_required (plaintext refused, token optional, pods send it) -> enforced (token required). Create new instances with enforced. No rollback below tls_required once enforced. AWS… |
| `sandbox_gcsfuse_enabled` | `sandbox_gcsfuse_enabled` | Boolean | no | yes | Enable GCS-fuse mount credentials for E2B sandboxes. |
| `sandbox_gcsfuse_key_json` | `sandbox_gcsfuse_key_json` | Password | no | yes | Service-account JSON used by E2B sandboxes to mount the intern data bucket with gcsfuse. |
| `sumble_api_key` | `sumble_api_key` | Password | no | yes | Sumble company-enrichment API key for this tenant. Per-customer; set at instance create and rotate via instance modify. Empty disables Sumble enrichment in intern. |
| `task_agent_use_agent_computer_runtime` | `task_agent_use_agent_computer_runtime` | String | no | yes | Legacy master toggle for agent-computer runtime; "1" enables computer runtime paths. |
| `temporal_codec_image` | `temporal_codec_image` | String | no | yes | Digest-pinned intern image providing the payload-codec HTTP server for the self-hosted Temporal Web UI (temporal_mode=self_hosted only). Must be a ghcr.io/pavoai image pinned @sha256 (terraform-validated), e.g. ghcr.io/pavoai/intern-temporal-worker@sha256:<digest>. The decode sidecar needs BOTH this AND a non-empty temporal_payload_codec_key — image-only enables nothing. Empty (default) = no code… |
| `temporal_history_shards` | `temporal_history_shards` | String | no | no | numHistoryShards for the self-hosted Temporal cluster (temporal_mode=self_hosted only). FROZEN at cluster creation — Temporal cannot change shard count on an existing cluster, so set this at instance CREATE for a known-large customer. Power of two, 16-16384. Default 128 fits per-customer cell load with ~100x headroom. Ignored on cloud. |
| `temporal_mode` | `temporal_mode` | String | no | no | Temporal hosting mode: 'cloud' (default — Temporal Cloud gdv7k, unchanged) or 'self_hosted' (per-instance Temporal server + dedicated RDS in this cluster; workflow state never leaves the VPC). Immutable per instance (shard count + PKI are frozen at cluster creation); requires grafana_mode=self_hosted. AWS BYOC only; unused on GCP. |
| `temporal_payload_codec_key` | `temporal_payload_codec_key` | Password | no | yes | Temporal payload codec key for this tenant. Must be EMPTY or exactly 64 hex characters (32 bytes) — terraform-validated; generate with `openssl rand -hex 32`. A base64 value (44 chars, trailing '=') is REJECTED at pavoInfra plan time. Per-customer v0 static key; set at instance create and rotate via instance modify. WARNING: changing this on a live instance makes previously encrypted Temporal pay… |
| `worker_proxy_routing_enabled` | `worker_proxy_routing_enabled` | Boolean | no | yes | Route sandbox worker egress through capability-proxy. |
| `zitadel_idp_id` | `zitadel_idp_id` | String | no | no | Pavo-internal. Zitadel OAuth IdP ID (google / oidc). Empty for no-IdP or SAML customers. Produced by pavo-customer-bootstrap. |
| `zitadel_issuer` | `zitadel_issuer` | String | yes | no | Pavo-internal. Produced by pavo-customer-bootstrap. Set once per customer. |
| `zitadel_mode` | `zitadel_mode` | String | no | yes | Identity hosting mode: 'cloud' (default — the shared central Zitadel at auth.pavoai.com, unchanged) or 'self_hosted' (a per-customer Zitadel + DB inside this instance's cluster; auth never leaves the VPC). Separate from es_mode/grafana_mode so identity can be flipped independently. AWS BYOC only; unused on GCP. |
| `zitadel_oidc_client_id` | `zitadel_oidc_client_id` | String | yes | no | Pavo-internal. Produced by pavo-customer-bootstrap. Set once per customer. |
| `zitadel_oidc_client_secret` | `zitadel_oidc_client_secret` | Password | yes | no | Pavo-internal. Produced by pavo-customer-bootstrap. Set once per customer. Masked in Omnistrate output (type Password). |
| `zitadel_org_id` | `zitadel_org_id` | String | yes | no | Pavo-internal. Produced by pavo-customer-bootstrap. Set once per customer. |
| `zitadel_org_primary_domain` | `zitadel_org_primary_domain` | String | yes | no | Pavo-internal. Customer-stable Zitadel org domain (<customer_name>.auth.pavoai.com). Produced by pavo-customer-bootstrap. |
| `zitadel_project_id` | `zitadel_project_id` | String | yes | no | Pavo-internal. Produced by pavo-customer-bootstrap. Set once per customer. |

## Omnistrate system values

Filled in by Omnistrate from the deployment cell or instance.

| Variable | Value |
|---|---|
| `aws_region` | The AWS region of the deployment cell. |
| `eks_cluster_name` | The EKS cluster name of the deployment cell. |
| `eks_oidc_provider` | The EKS cluster's OIDC issuer (for IRSA). |
| `instance_id` | The Omnistrate instance ID. |
| `vpc_id` | The VPC ID of the deployment cell. |

## Pavo-managed secrets

Set by Pavo from its secret store; the values are never shown.

| Variable | Description |
|---|---|
| `bitbucket_oauth_client_id` | Bitbucket OAuth app client ID used by tribal V8 generation to refresh tenant repo access tokens. |
| `bitbucket_oauth_client_secret` | Bitbucket OAuth app client secret used by tribal V8 generation to refresh tenant repo access tokens. |
| `elastic_api_key` | Elastic Cloud API key (for ec provider) |
| `gemini_api_key` | Google Gemini API key for AI-powered browser actions. |
| `ghcr_dockerconfig` | ghcr.io dockerconfigjson (org-scoped pavoai read credential, same one the service Helm charts use for image pulls). Materialized as the `pavo-ghcr-signature-pull` Secret in the instance namespace so the cell's Sigstore policy-controller can authenticate to private ghcr.io to fetch cosign signatures/attestations under enforce (referenced by each ClusterImagePolicy authority's signaturePullSecrets… |
| `hubspot_api_key` | Environment-level HubSpot private-app API key (from $secret.hubspot_api_key). Used when no per-tenant override is supplied. |
| `hubspot_client_secret` | Environment-level HubSpot app client secret for webhook signature verification (from $secret.hubspot_client_secret). Used when no per-tenant override is supplied. |
| `modal_token_id` | The token ID for Modal cloud compute platform. |
| `modal_token_secret` | The token secret for Modal cloud compute platform. |

## Module defaults

Not set by Omnistrate, so the module's own default applies.

| Variable | Default | Sensitive | Description |
|---|---|---|---|
| `account_id` | **required, no default** | no |  |
| `base_domain` | default | no | Fallback base domain for customer frontends when app_domain is empty (e.g., 'pavoai.dev'). |
| `db_instance_class` | default | no | RDS instance class for the PostgreSQL instance |
| `elasticsearch_api_key` | default | yes | Elasticsearch API key (for imported clusters) |
| `enable_vpc_endpoints` | default | no | Provision VPC interface endpoints (AWS PrivateLink) for Bedrock (control plane + runtime), KMS, Secrets Manager, ECR, SQS, SNS, STS, RDS, ElastiCache, EFS, IAM, and SES (when email is enabled) so those AWS API calls never traverse the public internet. Default true — small hourly cost per endpoint, and required for the zero-egress posture on strict BYOC (e.g. healthcare) and for instance tofu on a… |
| `extra_cors_origins` | default | no | Additional S3 CORS origins for direct Terraform module consumers. Not exposed as an Omnistrate apiParameter. |
| `postgres_engine_version` | default | no | RDS PostgreSQL engine version for the app + (self-hosted) Temporal databases. NOT hardcoded: AWS retires specific minor versions over time, and a pinned minor keeps working for existing (grandfathered) instances while silently breaking the NEXT new-instance create ("Cannot find version X for postgres"). Bump this default to a currently-creatable minor when AWS deprecates the old one. Check with:… |
| `primary_external_identity_provider_saml_metadata_xml` | default | yes | self_hosted only: raw SAML metadata XML for direct Terraform callers. pavoInfra base64encodes this (the one allowed identity transform) before handing it to pavo-customer-bootstrap. When both XML forms are set, xml_base64 wins. |
| `publisher_image` | default | no |  |
| `redis_node_type` | default | no | ElastiCache node type for gateway, intern, and onboarding Redis. |
| `region` | **required, no default** | no |  |
| `requested_enabled` | default | no |  |
| `revision` | default | no |  |
| `stored_config` | default | no | Previously persisted non-secret release configuration, or empty when not enabled yet. |
| `zitadel_provisioner_image` | default | no | Digest-pinned zitadel-provisioner image (ghcr.io/pavoai/zitadel-provisioner@sha256:...). Built + cosign-signed + attested (SBOM/vuln/OpenVEX) by the zitadel-provisioner-omnistrate Cloud Build trigger; pin the resulting digest here. See zitadel-provisioner/SIGNING.md. |
