# Opt-in, per-instance managed MicroVM image publisher. The resulting AWS image
# is intentionally external to Terraform state: disabling this feature must not
# delete an image that a running release may still reference.

variable "aws_microvm_managed_image_enabled" {
  description = "Run the per-instance managed MicroVM image publisher Job. After first enable, omitted/default inputs retain the persisted release; disabling requires an explicit operator migration."
  type        = bool
  default     = false
}

variable "aws_microvm_publisher_image" {
  description = "Digest-pinned ghcr.io/pavoai/microvm-publisher image."
  type        = string
  default     = ""
  validation {
    condition     = var.aws_microvm_publisher_image == "" || can(regex("^ghcr\\.io/pavoai/microvm-publisher@sha256:[0-9a-f]{64}$", var.aws_microvm_publisher_image))
    error_message = "aws_microvm_publisher_image must be empty or a sha256 digest-pinned ghcr.io/pavoai/microvm-publisher image."
  }
}

variable "aws_microvm_image_revision" {
  description = "Immutable application release identifier included in the managed image identity."
  type        = string
  default     = ""
  validation {
    condition     = var.aws_microvm_image_revision == "" || can(regex("^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$", var.aws_microvm_image_revision))
    error_message = "aws_microvm_image_revision must be empty or an immutable 1-128 character release identifier."
  }
}

variable "aws_microvm_image_arn" {
  description = "Existing customer-account MicroVM image ARN for manual mode."
  type        = string
  default     = ""
}

variable "aws_microvm_region" {
  description = "Region of the existing MicroVM image for manual mode."
  type        = string
  default     = ""
}

variable "aws_microvm_worker_secret" {
  description = "Worker secret paired with the existing MicroVM image for manual mode."
  type        = string
  default     = ""
  sensitive   = true
}

# List instead of Get: absent config (including a first-install namespace) is
# an empty result. Keep this read independent of namespace/config writes so the
# effective resource counts are known during planning.
data "kubernetes_resources" "microvm_config" {
  api_version    = "v1"
  kind           = "ConfigMap"
  namespace      = var.instance_id
  field_selector = "metadata.name=pavo-microvm-release-config"
}

module "microvm_config" {
  source            = "./modules/microvm_config"
  account_id        = data.aws_caller_identity.current.account_id
  instance_id       = var.instance_id
  region            = var.aws_region
  requested_enabled = var.aws_microvm_managed_image_enabled
  publisher_image   = var.aws_microvm_publisher_image
  revision          = var.aws_microvm_image_revision
  stored_config     = try(data.kubernetes_resources.microvm_config.objects[0].data["release.json"], "")
}

# Only non-secret release inputs are persisted. Existing namespace permissions
# suffice; no additional customer AWS runner permissions are required.
resource "kubernetes_config_map_v1" "microvm_config" {
  count = local.microvm_count
  metadata {
    name      = "pavo-microvm-release-config"
    namespace = var.instance_id
  }
  data = { "release.json" = module.microvm_config.manifest }
  lifecycle { prevent_destroy = true }
  depends_on = [kubectl_manifest.instance_namespace, terraform_data.microvm_mode, terraform_data.microvm_prerequisites]
}

locals {
  # Strict cells have no MicroVM control-plane path. Force count=0 so a leftover
  # release ConfigMap or enable param cannot provision (or fail-closed).
  microvm_count              = var.network_posture == "strict" ? 0 : (module.microvm_config.enabled ? 1 : 0)
  microvm_publisher_sa       = "pavo-microvm-publisher"
  microvm_source_digest      = trimprefix(module.microvm_config.publisher_image, "ghcr.io/pavoai/microvm-publisher@sha256:")
  microvm_release_hash       = local.microvm_count == 1 ? substr(sha256("${local.microvm_source_digest}:${module.microvm_config.revision}:${nonsensitive(random_password.microvm_worker_secret[0].result)}"), 0, 20) : "disabled"
  microvm_image_name         = "pavo-microvm-${substr(var.instance_id, 0, 30)}-${local.microvm_release_hash}"
  microvm_expected_image_arn = "arn:aws:lambda:${var.aws_region}:${data.aws_caller_identity.current.account_id}:microvm-image:${local.microvm_image_name}"
  microvm_artifact_prefix    = "microvm-images/${local.microvm_image_name}"
  microvm_manifest           = local.microvm_count == 1 ? jsondecode(data.aws_s3_object.microvm_release[0].body) : {}
  microvm_manual_value_count = nonsensitive(length(compact([
    var.aws_microvm_image_arn,
    var.aws_microvm_region,
    var.aws_microvm_worker_secret,
  ])))
}

resource "terraform_data" "microvm_mode" {
  count      = local.microvm_count
  input      = module.microvm_config.enabled
  depends_on = [module.microvm_config]

  lifecycle {
    precondition {
      condition     = local.microvm_manual_value_count == 0 || local.microvm_manual_value_count == 3
      error_message = "Manual MicroVM mode requires image ARN, region, and worker secret together."
    }
    precondition {
      condition     = !module.microvm_config.enabled || local.microvm_manual_value_count == 0
      error_message = "Managed MicroVM image mode and the manual image override are mutually exclusive."
    }
    precondition {
      condition     = !module.microvm_config.enabled || var.network_posture == "standard"
      error_message = "Managed MicroVM image publishing currently requires network_posture = standard; strict egress does not yet allow the MicroVM control-plane endpoint."
    }
    precondition {
      condition = (
        !module.microvm_config.enabled ||
        (module.microvm_config.publisher_image != "" && module.microvm_config.revision != "")
      )
      error_message = "Managed MicroVM images require a digest-pinned publisher image and immutable image revision."
    }
  }
}

resource "aws_s3_bucket" "microvm_image" {
  count         = local.microvm_count
  bucket_prefix = "pavo-microvm-${substr(var.instance_id, 0, 24)}-"
  force_destroy = false

  lifecycle { prevent_destroy = true }
  depends_on = [kubernetes_config_map_v1.microvm_config]
}

resource "aws_s3_bucket_public_access_block" "microvm_image" {
  count                   = local.microvm_count
  bucket                  = aws_s3_bucket.microvm_image[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "microvm_image" {
  count  = local.microvm_count
  bucket = aws_s3_bucket.microvm_image[0].id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "microvm_image" {
  count  = local.microvm_count
  bucket = aws_s3_bucket.microvm_image[0].id
  rule {
    apply_server_side_encryption_by_default {
      kms_master_key_id = data.aws_kms_key.cell_cmk.arn
      sse_algorithm     = "aws:kms"
    }
    bucket_key_enabled = true
  }
}

data "aws_iam_policy_document" "microvm_publisher_assume" {
  count = local.microvm_count
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/${var.eks_oidc_provider}"]
    }
    condition {
      test     = "StringEquals"
      variable = "${var.eks_oidc_provider}:sub"
      values   = ["system:serviceaccount:${var.instance_id}:${local.microvm_publisher_sa}"]
    }
    condition {
      test     = "StringEquals"
      variable = "${var.eks_oidc_provider}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "microvm_build_assume" {
  count = local.microvm_count
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "microvm_publisher" {
  count                = local.microvm_count
  name                 = substr("pavo-microvm-publisher-${var.instance_id}", 0, 64)
  assume_role_policy   = data.aws_iam_policy_document.microvm_publisher_assume[0].json
  permissions_boundary = local.microvm_publisher_boundary_arn
  depends_on           = [kubernetes_config_map_v1.microvm_config]
}

resource "aws_iam_role" "microvm_build" {
  count                = local.microvm_count
  name                 = substr("pavo-microvm-build-${var.instance_id}", 0, 64)
  assume_role_policy   = data.aws_iam_policy_document.microvm_build_assume[0].json
  permissions_boundary = local.microvm_build_boundary_arn
  depends_on           = [kubernetes_config_map_v1.microvm_config]
}

data "aws_iam_policy_document" "microvm_publisher" {
  count = local.microvm_count
  statement {
    sid       = "ArtifactBucket"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.microvm_image[0].arn]
    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["${local.microvm_artifact_prefix}/*"]
    }
  }
  statement {
    sid       = "ArtifactObjects"
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:PutObject"]
    resources = ["${aws_s3_bucket.microvm_image[0].arn}/${local.microvm_artifact_prefix}/*"]
  }
  statement {
    sid       = "ArtifactKms"
    effect    = "Allow"
    actions   = ["kms:Decrypt", "kms:Encrypt", "kms:GenerateDataKey", "kms:DescribeKey"]
    resources = [data.aws_kms_key.cell_cmk.arn]
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["s3.${var.aws_region}.amazonaws.com"]
    }
  }
  # AWS does not expose a resource ARN to authorize before the image exists.
  # Constrain creation by region here; all subsequent reads use the exact ARN.
  statement {
    sid       = "CreateMicrovmImage"
    effect    = "Allow"
    actions   = ["lambda:CreateMicrovmImage"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.aws_region]
    }
  }
  # AWS evaluates tagging during image creation against "*". Named Lambda
  # ARNs are excluded, so the publisher cannot retag existing resources.
  # Only the pinned provenance digest and its single tag key are accepted.
  statement {
    sid           = "TagOnCreateOnly"
    effect        = "Allow"
    actions       = ["lambda:TagResource"]
    not_resources = ["arn:aws:lambda:*:*:*"]
    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.aws_region]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/source_digest"
      values   = [local.microvm_source_digest]
    }
    condition {
      test     = "ForAllValues:StringEquals"
      variable = "aws:TagKeys"
      values   = ["source_digest"]
    }
    condition {
      test     = "Null"
      variable = "aws:TagKeys"
      values   = ["false"]
    }
  }
  # The managed base implicitly uses AWS's INTERNET_EGRESS connector.
  # AWS requires Resource "*" for this permission-only action.
  statement {
    sid       = "PassImageNetworkConnector"
    effect    = "Allow"
    actions   = ["lambda:PassNetworkConnector"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.aws_region]
    }
  }
  statement {
    sid       = "ReadMicrovmImage"
    effect    = "Allow"
    actions   = ["lambda:GetMicrovmImage", "lambda:GetMicrovmImageVersion", "lambda:ListMicrovmImageVersions"]
    resources = [local.microvm_expected_image_arn]
  }
  statement {
    sid       = "DiscoverManagedImages"
    effect    = "Allow"
    actions   = ["lambda:ListManagedMicrovmImages"]
    resources = ["*"]
  }
  statement {
    sid       = "PassBuildRole"
    effect    = "Allow"
    actions   = ["iam:PassRole"]
    resources = [aws_iam_role.microvm_build[0].arn]
    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["lambda.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "microvm_build" {
  count = local.microvm_count
  statement {
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.microvm_image[0].arn}/${local.microvm_artifact_prefix}/*"]
  }
  statement {
    effect    = "Allow"
    actions   = ["kms:Decrypt", "kms:DescribeKey"]
    resources = [data.aws_kms_key.cell_cmk.arn]
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["s3.${var.aws_region}.amazonaws.com"]
    }
  }
  statement {
    sid       = "CreateBuildLogGroup"
    effect    = "Allow"
    actions   = ["logs:CreateLogGroup"]
    resources = ["arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda-microvms/${local.microvm_image_name}"]
  }
  statement {
    sid     = "WriteBuildLogStream"
    effect  = "Allow"
    actions = ["logs:CreateLogStream", "logs:PutLogEvents"]
    # IAM simulation currently returns implicitDeny for this documented ARN
    # form. Do not broaden the build role to all log groups; an actual Dev image
    # build is the rollout gate for resolving the simulator discrepancy.
    resources = ["arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda-microvms/${local.microvm_image_name}:log-stream:*"]
  }
}

resource "aws_iam_role_policy" "microvm_publisher" {
  count  = local.microvm_count
  name   = "microvm-publisher"
  role   = aws_iam_role.microvm_publisher[0].id
  policy = data.aws_iam_policy_document.microvm_publisher[0].json
}

resource "aws_iam_role_policy" "microvm_build" {
  count  = local.microvm_count
  name   = "microvm-build"
  role   = aws_iam_role.microvm_build[0].id
  policy = data.aws_iam_policy_document.microvm_build[0].json
}

resource "random_password" "microvm_worker_secret" {
  count      = local.microvm_count
  length     = 48
  special    = false
  depends_on = [kubernetes_config_map_v1.microvm_config]
}

resource "kubernetes_secret_v1" "microvm_worker" {
  count = local.microvm_count
  metadata {
    name      = "pavo-microvm-worker-${local.microvm_release_hash}"
    namespace = var.instance_id
  }
  data       = { WORKER_API_SECRET = random_password.microvm_worker_secret[0].result }
  depends_on = [kubectl_manifest.instance_namespace, terraform_data.microvm_mode]
}

resource "kubernetes_service_account_v1" "microvm_publisher" {
  count = local.microvm_count
  metadata {
    name        = local.microvm_publisher_sa
    namespace   = var.instance_id
    annotations = { "eks.amazonaws.com/role-arn" = aws_iam_role.microvm_publisher[0].arn }
  }
  depends_on = [kubectl_manifest.instance_namespace]
}

resource "kubernetes_job_v1" "microvm_publisher" {
  count = local.microvm_count
  metadata {
    name      = "pavo-microvm-publisher-${local.microvm_release_hash}"
    namespace = var.instance_id
  }
  spec {
    active_deadline_seconds = 2100
    backoff_limit           = 1
    template {
      metadata { labels = { "app.kubernetes.io/name" = "pavo-microvm-publisher" } }
      spec {
        restart_policy       = "Never"
        service_account_name = kubernetes_service_account_v1.microvm_publisher[0].metadata[0].name
        enable_service_links = false
        image_pull_secrets { name = "pavo-ghcr-signature-pull" }
        toleration {
          key      = "CriticalAddonsOnly"
          operator = "Exists"
        }
        security_context {
          run_as_non_root = true
          run_as_user     = 1000
          run_as_group    = 1000
          fs_group        = 1000
          seccomp_profile { type = "RuntimeDefault" }
        }
        container {
          name              = "publisher"
          image             = module.microvm_config.publisher_image
          image_pull_policy = "IfNotPresent"
          resources {
            requests = { cpu = "250m", memory = "256Mi" }
            limits   = { cpu = "1", memory = "1Gi" }
          }
          security_context {
            allow_privilege_escalation = false
            read_only_root_filesystem  = true
            run_as_non_root            = true
            run_as_user                = 1000
            capabilities { drop = ["ALL"] }
          }
          volume_mount {
            name       = "tmp"
            mount_path = "/tmp"
          }
          env {
            name  = "EXPECTED_AWS_ACCOUNT_ID"
            value = data.aws_caller_identity.current.account_id
          }
          env {
            name  = "AWS_REGION"
            value = var.aws_region
          }
          env {
            name  = "MICROVM_IMAGE_NAME"
            value = local.microvm_image_name
          }
          env {
            name  = "MICROVM_ARTIFACT_BUCKET"
            value = aws_s3_bucket.microvm_image[0].id
          }
          env {
            name  = "MICROVM_BUILD_ROLE_ARN"
            value = aws_iam_role.microvm_build[0].arn
          }
          env {
            name  = "MICROVM_SOURCE_DIGEST"
            value = local.microvm_source_digest
          }
          env {
            name = "WORKER_API_SECRET"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.microvm_worker[0].metadata[0].name
                key  = "WORKER_API_SECRET"
              }
            }
          }
        }
        volume {
          name = "tmp"
          empty_dir {
            size_limit = "1Gi"
          }
        }
      }
    }
  }
  wait_for_completion = true
  timeouts { create = "40m" }

  depends_on = [
    aws_s3_bucket_server_side_encryption_configuration.microvm_image,
    aws_s3_bucket_public_access_block.microvm_image,
    aws_iam_role_policy.microvm_publisher,
    aws_iam_role_policy.microvm_build,
    kubernetes_secret_v1.ghcr_signature_pull,
    terraform_data.microvm_mode,
  ]

}

data "aws_s3_object" "microvm_release" {
  count      = local.microvm_count
  bucket     = aws_s3_bucket.microvm_image[0].id
  key        = "${local.microvm_artifact_prefix}/release.json"
  depends_on = [kubernetes_job_v1.microvm_publisher]

  lifecycle {
    postcondition {
      condition = (
        try(jsondecode(self.body).image_arn, "") == local.microvm_expected_image_arn &&
        try(jsondecode(self.body).account_id, "") == data.aws_caller_identity.current.account_id &&
        try(jsondecode(self.body).region, "") == var.aws_region &&
        try(jsondecode(self.body).source_digest, "") == local.microvm_source_digest
      )
      error_message = "Publisher release.json does not match the expected image ARN, AWS account, region, and source digest."
    }
  }
}

output "aws_microvm_resolved_image_arn" {
  description = "Effective image ARN: verified managed release, or the complete manual override."
  value       = local.microvm_count == 1 ? try(local.microvm_manifest.image_arn, "") : var.aws_microvm_image_arn
}

output "aws_microvm_resolved_region" {
  description = "Region paired with the effective MicroVM image."
  value       = local.microvm_count == 1 ? try(local.microvm_manifest.region, "") : var.aws_microvm_region
}

output "aws_microvm_resolved_worker_secret" {
  description = "Worker secret paired with the effective MicroVM image."
  value       = local.microvm_count == 1 ? try(local.microvm_manifest.image_arn != "" ? random_password.microvm_worker_secret[0].result : "", "") : var.aws_microvm_worker_secret
  sensitive   = true
}
