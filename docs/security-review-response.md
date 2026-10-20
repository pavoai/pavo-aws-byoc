# BYOC security-review response

This is the reply we sent, mapped to the Terraform in this snapshot.
It is **what the code does today**, not a restatement of the email.

Encryption-at-rest decision (the open question in §3): **customer-managed CMK**.
Every new instance on this branch takes `cell_kms_key_arn`. Existing Redis
groups, SNS topics, and EFS filesystems keep the key they were created with
(`lifecycle.ignore_changes`) so a live cell is not ForceNew-recreated.

Stage 1 = `pavo-bootstrap-aws/` (customer-applied, once per cell).
Stage 2 = `terraform-omnistrate-aws/` (Omnistrate runner, once per instance).

| Status | Meaning |
|---|---|
| **Shipped** | Agreed change is in this branch |
| **Shipped, not default** | Control exists; `standard` / existing cells keep the old default |
| **Clarification** | We explained the current design; no code change |
| **Omnistrate** | Their CloudFormation / runner-account work, not this repo |
| **Mid-POC** | Proposed for the POC; not a start blocker; not in this branch |
| **Waiting** | Still needs a customer yes/no |

Private-cell create settings this reply assumes:

- `network_posture = strict`, with `es_mode` / `grafana_mode` / `temporal_mode`
  / `zitadel_mode` all `self_hosted` at **create**
- Stage 1: `install_private_ca = true`, `network_policy_ready = true`,
  `enable_eck = true`, `enable_observability = true`
- `langfuse_enabled` / `hubspot_enabled` / OpenAI keys can stay at whatever
  the portal stores; strict Helm blanks them on every render
- `llm_cloud_only` is forced `true` on strict even if someone later sets it
  false
- `redis_security_phase = enforced` and `efs_iam_auth_enforced = true` on
  **new** instances (both still default `false`/`off` so existing cells do
  not break)

---

## 1. Network isolation and external services

**Reply:** Clarification provided.

`network_posture = strict` is the umbrella. It is not a checklist of
independent flags the operator must keep set. After a private cell is on
strict, later changes to the portal / instance parameters do **not** take
effect: Helm and OpenTofu both ignore the stored values and apply the strict
profile.

Two layers:

1. **Helm `aws-strict-profile` (later than `$var`).** Spec comment:
   “Stored portal params are not rewritten; this layer overrides `$var`.”
   On every Helm render, a strict instance gets Bedrock-only LLM, empty
   OpenAI / Anthropic / E2B / MicroVM / Slack / HubSpot / Langfuse / Brevo
   secrets, `llmCloudOnly: true`, Titan embeddings, `pavo_custom` computer,
   and MicroVMs/E2B/Modal off. Enabling Langfuse or pasting an OpenAI key
   in the UI is a no-op while posture stays `strict`.
2. **OpenTofu `effective_*` in `strict_profile.tf`.** While posture is
   `strict`, ES / Grafana / Temporal / Zitadel are `self_hosted` regardless
   of `var.es_mode` (and the other three). Outputs and resource counts use
   those locals. Create still requires the four flags to already be
   `self_hosted` so we do not replace Elastic Cloud / Temporal Cloud /
   central Zitadel / Grafana Cloud on a live cell; flipping them to `cloud`
   on a strict instance fails plan instead of migrating data.

| Claim in the reply | Code | Status |
|---|---|---|
| Strict is the single control; stored values cannot reopen egress | Helm `aws-strict-profile` on api-gateway, intern, onboarding-copy, tribal-knowledge. Scoped `network_posture: strict`. Overrides `$var` every render. | **Shipped** |
| Self-hosted ES / Temporal / identity / Grafana | `local.effective_*_mode = "self_hosted"` when strict. Plan fails if the four create flags are not already `self_hosted`. | **Shipped** |
| MicroVMs disabled on strict | Same Helm layer blanks image/ARN/secret after `aws-microvm-resolved`, so empty wins. `enable_lambda_microvms` is deprecated and **not read**; workload MicroVM IAM is unconditional; the account ceiling is the permission boundary. | **Shipped** |
| `llm_cloud_only = true`, Bedrock in-account | Strict Helm forces `llmCloudOnly: true`, `llmProvider: bedrock`, Titan embeddings. Bedrock stays on a VPC interface endpoint. | **Shipped** |
| OpenAI / Anthropic / Langfuse / HubSpot off | Strict Helm blanks keys/flags even if defaults or later modifies set them. | **Shipped** |

Default posture is still `standard` (no override layer). The private cell
must be created `strict`; after that the umbrella holds the runtime closed.

---

## 2. IAM permissions and secret isolation

**Reply:** Accepted, with clarification.

Agreed: restrict the provisioning runner (EC2 tagging, ENI, EKS); keep RDS and
ElastiCache management off the application runtime role; replace the
cluster-wide `ClusterSecretStore` with namespace-scoped stores and
deployment-specific reader roles. Omnistrate owns CloudFormation PassRole,
duplicate roles, repeated policies, and SID corrections.

Clarification: the runner’s trust-policy update covers `pavo-*` and `keda-*`,
including the Pavo ESO role.

| Agreed change | Code | Status |
|---|---|---|
| Runner EC2 tagging and ENI | `policy-statements.json`: tags require `managed_by=pavo` and `instance=instance-*`. ENI create/modify/delete only with `aws:CalledViaLast=elasticfilesystem.amazonaws.com`; `DenyDirectENIWrites` blocks a direct EC2 call. | **Shipped** |
| Runner EKS | `EKSAccessAndDescribe` is `cluster/hc-*` (`DescribeCluster`, `AccessKubernetesApi`). Access-entry writes dropped. `eks:ListClusters` stays on `*` (no resource ARN for that action). | **Shipped** |
| Runner KMS (related lock, same pass) | Boundary crypto is `kms:ViaService`. Runner `DescribeKey` / grants use `kms:ResourceAliases = alias/pavo-*`. | **Shipped** |
| RDS / ElastiCache mutating APIs off the app role | `rds:*` / `elasticache:*` are `scope: runner` in `policy-statements.json`. The workload role has no `rds-db:connect` and no `elasticache:Connect`. | **Shipped** |
| Namespaced SecretStore + per-instance reader | Stage 2: `pavo-eso-<instance_id>` + namespaced `SecretStore` `pavo-aws-sm`, secret ARN = this instance’s RDS master secret, `kms:Decrypt` on the cell CMK via Secrets Manager. Cell ESO role **denies** secret/KMS reads unless `legacy_eso_cell_secret_read = true` (default `false`). | **Shipped** |
| `UpdateAssumeRolePolicy` on `pavo-*` / `keda-*` | Own SID, those name prefixes, plus `managed_by=pavo` and `instance=instance-*`. Covers instance ESO (`pavo-eso-<instance_id>`) and KEDA. | **Clarification** |
| CloudFormation PassRole / duplicate roles / SIDs | Not in this repo. | **Omnistrate** |

`rds:*` / `s3:*` / `sns:*` / `sqs:*` / `elasticache:*` on `pavo-*` name
prefixes are still action-wildcards for the **runner**. That is the leftover
hygiene in §6, not the runtime isolation the reviewer failed.

---

## 3. Encryption and authentication

**Reply:** Accepted; we asked CMK vs AWS-managed. **CMK is the path taken.**

Agreed: Redis TLS + AUTH and update consumers; verify RDS TLS; document
ESO-managed password auth; remove unused `rds-db:connect`. EFS (README vs
SG, filesystem TLS/IAM, cluster-SG NFS) was agreed as mid-POC; it is on
this branch.

### At rest — customer CMK

`cell_kms_key_arn` is required. New resources use it. Existing Redis / SNS /
EFS keep their current key (`ignore_changes`) so we do not recreate live data
stores. After they chose CMK everywhere, app S3, SQS, the node EBS default,
and the stage-1 state bucket moved onto that key as well.

| Store | New instance | Existing instance |
|---|---|---|
| RDS (app + Temporal) + master-password secret | Cell CMK | Cell CMK |
| Self-hosted ES EBS + snapshot bucket | Cell CMK | Cell CMK |
| Zitadel identity-state bucket | Cell CMK | Cell CMK |
| ElastiCache Redis | Cell CMK | Keep previous key |
| SNS topics | Cell CMK | Keep previous key |
| EFS | Cell CMK, **all postures** (not strict-only) | Keep previous key (ForceNew if you change it) |
| App S3 (`onboarding`, `data`) | Cell CMK (new objects) | Existing objects stay SSE-S3 until rewritten |
| SQS (worker + connector_sync) | Cell CMK | Cell CMK |
| Node EBS default / keyless gp3 | Cell CMK (account+region default) | Existing volumes keep their key until replaced |
| Stage 1 TF state bucket | Cell CMK when `create-state-backend.sh` is passed the key | Re-run the script with the CMK |

The provider-mirror bucket stays SSE-S3 (public OpenTofu providers, not customer data).

### In transit / auth — agreed items

| Agreed change | Code | Status |
|---|---|---|
| Redis TLS + AUTH | `redis_security_phase`: `off` → `tls_preferred` → `tls_required` → `enforced`. Apps must move with the phase (rediss://, then token). | **Shipped, not default** (`off`). Private-cell create should pass `enforced`. |
| RDS password auth + drop `rds-db:connect` | Apps use the Secrets Manager password via the namespaced SecretStore. `rds-db:connect` is **gone** from the workload policy. This module does **not** create an RDS parameter group and does **not** set `rds.force_ssl`. | **Shipped** for the grant and password auth. TLS-required is **not in this branch**. |

### EFS hardening (agreed mid-POC; shipped)

The reply put filesystem TLS/IAM and narrower NFS access after start. The
controls are in this branch. New private-cell instances should pass
`efs_iam_auth_enforced = true`; the Terraform default stays `false` so a live
cell with anonymous PVs is not denied on remount.

| Item | Code | Status |
|---|---|---|
| Filesystem TLS | `aws_efs_file_system_policy.pavo` `DenyNonTls` | **Shipped** |
| Filesystem IAM | `efs_iam_auth_enforced`: policy principals = CSI node role; StorageClass `iam` mount option. Default `false`. | **Shipped, not default** |
| Narrower EFS network | `aws_security_group.efs` ingress 2049 from the **EKS cluster SG**, not VPC CIDR | **Shipped** |

---

## 4. Terraform state locations

**Reply:** Clarification provided.

| Module | State | Status |
|---|---|---|
| Stage 2 `terraform-omnistrate-aws` | Omnistrate-managed (Pavo control plane; not the customer account) | **Clarification** |
| Stage 1 `pavo-bootstrap-aws` | Customer S3 | **Clarification** |
| Self-hosted Zitadel TF state | Customer S3 (`zitadel_provision.tf`) | Extra, in-account |
| Cloud identity (`pavo-customer-bootstrap`) | Pavo GCS — only if identity stays cloud. Strict / self-hosted identity does not use that bucket. | Out of band for a private cell |

No code change. A private cell still has stage 2 state (and secrets in that
state) outside the customer account. Teardown of that copy is §7.

---

## 5. Third-party container image verification

**Reply:** Clarification. The 1 Oct package said signatures are enforced.
That is how the policies are **written** (`ghcr.io/pavoai/<svc>*`,
`image_policy_mode = enforce`). A private cell does **not** pull those names,
so that check does not run on the images the pods actually start.

### What the cell does today

1. **Build and sign.** Cloud Build publishes `ghcr.io/pavoai/*` and
   cosign-signs them (signature + SBOM + vuln attestations).
2. **Copy.** `Publish Artifact Plane` `crane`-copies those **same digests**,
   plus the cell Helm images in `mirrored-images.json`, into provisioner ECR
   (`omnistrate/images/pavo/<upstream-host>/<path>`). Customer accounts are
   granted pull.
3. **Pull.** Helm on the cell uses the ECR name over the VPC endpoint.

ClusterImagePolicy globs are still `ghcr.io/pavoai/<svc>*`. Policy-controller
`no-match-policy = allow`. The ECR pull name does not match those globs, so
**admission admits the private-cell image without a signature check.**
Integrity on this cell today is digest pin + copy, not CIP. Signatures still
exist on GHCR for the same digest; they are not consulted at admit time for
the ECR name.

### Plan (before we claim enforce on this cell)

Add CIP globs for the artifact-plane ECR names (same digest; signatures still
read from GHCR via `pavo-ghcr-signature-pull`, or copied next to the ECR
digest). Keep `no-match-policy = allow` until those globs exist so a miss
does not reject the cell. Then CIP enforce applies to the pull name.

Non-Pavo images (ESO, ECK, Reloader, Prometheus, Grafana, OTel,
policy-controller, …): same digest pin + ECR copy; no CIP; one-time verify as
agreed; not changing mid-POC.

---

## 6. Configuration and code maintenance

**Reply:** Accepted.

| Agreed change | Code | Status |
|---|---|---|
| Redis sizing configurable, keep default | `var.redis_node_type` (default `cache.t3.medium`) on all three groups. Not an Omnistrate apiParameter; a change resizes immediately. | **Shipped** |
| ESO Helm chart version configurable, keep 0.10.4 and compatibility | `var.external_secrets_chart_version` (default `0.10.4`) and `var.reloader_chart_version` (default `1.1.0`). Image tags stay in `mirrored-images.json`. | **Shipped** |
| Consolidate S3 and SNS/SQS with `moved` | App buckets `onboarding` / `intern_data` → `aws_s3_bucket.pavo`. Worker topics/queues → `aws_sns_topic.pavo` / `aws_sqs_queue.worker`. Live addresses remapped with `moved`. `connector_sync` stays a separate one-topic / N-queue stack (filter policy); Redis groups were never this item. | **Shipped** |
| Replace inline RDS CA bundle with a CI-generated, verified artifact | Size was the concern. `temporal_rds_ca_bundle.tf` is **76 lines**: one RSA2048 G1 root each for `us-east-1` and `us-east-2`, coupled to `ca_cert_identifier = rds-ca-rsa2048-g1`. Was 2,757 lines / 108 CAs. Still a `.tf` literal because Omnistrate git ingestion only materializes `.tf` onto the executor. | **Shipped** |

---

## 7. Teardown and decommissioning

**Reply:** Proposed for mid-POC (not a start blocker).

| Item | Today | Mid-POC |
|---|---|---|
| Customer approval before destructive ops | None. `omnistrate-ctl instance modify` or documented `aws rds modify-db-instance --no-deletion-protection`. | Approval + split backup-delete perms |
| Protect final snapshots / automated backups | `create_final_snapshot` default `true`. Runner `rds:*` includes `snapshot:pavo-*`. `delete_automated_backups` unset → provider default `true`. | Protect `pavo-final-*`; agree retention |
| EFS backup | None | AWS Backup / similar |
| ES snapshot bucket | SSE-KMS, **not versioned**, `force_destroy` gated | Versioning + keep on destroy |
| Off-account deletion evidence | No runbook for Elastic Cloud (if used), Temporal Cloud (if used), Omnistrate stage 2 state, Pavo GCS (cloud identity only), Langfuse/HubSpot (off on private cell) | Procedure + evidence pack |
| Cleanup leftovers | Namespace `apply_only`. Cell CIP / IngressClass / ClusterIssuer stay (shared). EFS StorageClass is cluster-scoped with `instance_id` in the name. `keda-sqs-scaler` is account-named — destroying the owning instance removes it for the account. | Verify instance leftovers; keep shared roles |

**Status:** **Mid-POC.** Defaults remain safe (`rds_deletion_protection = true`,
`force_destroy_buckets = false`).

---

## Inputs from the reply — current answers

| Input | Answer on this branch |
|---|---|
| Preferred encryption at rest | **Customer-managed CMK** (`cell_kms_key_arn`), including app S3, SQS, node EBS default, and the stage-1 state bucket. Existing Redis/SNS/EFS keys are left in place. |
| Third-party image verification: POC-start blocker or before production? | **Not a start blocker.** Private-cell pulls are ECR names; CIP globs still match GHCR only, so admission does not check those pulls today. Plan: CIP globs for the ECR names. Non-Pavo stay digest-pinned; one-time verify as agreed. |
| EFS hardening + teardown during the POC? | **EFS shipped** (TLS deny, IAM opt-in, cluster-SG NFS). **Teardown** still §7 / mid-POC. |

---

## Not in the reply, still true if someone re-reads the old scorecard

- Stage 2 roles still attach the permission boundary; runner cannot create
  `pavo-*` / `keda-*` without one.
- Runner action-wildcards on `pavo-*` RDS/S3/SNS/SQS/ElastiCache remain.
