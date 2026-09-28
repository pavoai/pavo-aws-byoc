# =============================================================================
# Self-hosted Elasticsearch — snapshot substrate (C3)
# =============================================================================
# Adds the backup path for the self_hosted ES cluster (C2): a dedicated
# SSE-KMS S3 bucket under the customer CMK, the S3+KMS IAM policy on the snapshot
# role, and a one-shot idempotent bootstrap Job that registers the repo + SLM.
# All count-gated on es_mode = "self_hosted" (local.es_count from C2). Validated
# live on an internal test instance in the Phase 0 spike (snapshot -> restore under the customer
# CMK, _verify passed first try).

locals {
  es_snapshot_bucket = "pavo-${var.customer_name}-es-snap-${var.instance_id}"
  es_snapshot_repo   = "pavo_s3"

  # curlimages/curl 8.10.1 (stock public image, matches the create_databases
  # infra-Job convention; Sigstore policy-controller admits non-ghcr.io/pavoai
  # images). Digest-pinned: this Job runs with ES bootstrap credentials, so
  # pinning prevents an upstream tag move from swapping the trusted executable.
  es_bootstrap_image = "curlimages/curl:8.10.1@sha256:a73e4b2a41674e127042302efd0c237a44b029ca616d640945597666cddf53ca"

  # Repo register + _verify + SLM. Shell vars ($USER/$PASS/$ES_URL/$SNAPSHOT_BUCKET)
  # come from the container env; the until-loop also rides out the file-realm
  # reload lag (first calls 401 until ECK syncs the bootstrap user).
  es_bootstrap_script = <<-EOT
    set -e
    until curl -fsS --cacert /etc/es-ca/ca.crt -u "$USER:$PASS" \
      "$ES_URL/_cluster/health?wait_for_status=yellow&timeout=60s"; do
      echo "waiting for Elasticsearch..."; sleep 10
    done
    # Register S3 repo. NO server_side_encryption flag (that requests AES256, not
    # the CMK) — the bucket's SSE-KMS default applies the customer key.
    curl -fsS --cacert /etc/es-ca/ca.crt -u "$USER:$PASS" -XPUT "$ES_URL/_snapshot/pavo_s3" \
      -H 'Content-Type: application/json' \
      -d "{\"type\":\"s3\",\"settings\":{\"bucket\":\"$SNAPSHOT_BUCKET\",\"base_path\":\"repositories/pavo-es-primary\",\"compress\":true}}"
    # _verify surfaces broken IRSA/KMS/endpoint wiring at provision time (fails the Job).
    curl -fsS --cacert /etc/es-ca/ca.crt -u "$USER:$PASS" -XPOST "$ES_URL/_snapshot/pavo_s3/_verify"
    # SLM: every 30 min, retain 7d (min 24 / max 336). SLM is the SOLE deleter.
    curl -fsS --cacert /etc/es-ca/ca.crt -u "$USER:$PASS" -XPUT "$ES_URL/_slm/policy/pavo_30m_7d" \
      -H 'Content-Type: application/json' \
      -d '{"schedule":"0 */30 * * * ?","name":"<pavo-snap-{now/d{yyyy.MM.dd-HH.mm}}>","repository":"pavo_s3","config":{"indices":["*"],"include_global_state":false},"retention":{"expire_after":"7d","min_count":24,"max_count":336}}'
  EOT

  # Config-hash in the Job name -> a config change recreates (re-runs) the Job;
  # the repo/SLM PUTs are idempotent upserts so re-runs are no-ops.
  es_bootstrap_hash = substr(sha1(local.es_bootstrap_script), 0, 8)
}

# -----------------------------------------------------------------------------
# Dedicated snapshot bucket — SSE-KMS default = customer CMK (INV-1/2)
# -----------------------------------------------------------------------------
resource "aws_s3_bucket" "es_snapshots" {
  count = local.es_count

  bucket        = local.es_snapshot_bucket
  force_destroy = var.force_destroy_buckets

  tags = { Name = local.es_snapshot_bucket }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "es_snapshots" {
  count  = local.es_count
  bucket = aws_s3_bucket.es_snapshots[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = var.cell_kms_key_arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "es_snapshots" {
  count  = local.es_count
  bucket = aws_s3_bucket.es_snapshots[0].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Lifecycle MUST NOT age-delete repository objects — an ES snapshot repo is
# incremental, so external deletion corrupts it (SLM retention is the sole
# deleter). Only reap incomplete multipart uploads.
resource "aws_s3_bucket_lifecycle_configuration" "es_snapshots" {
  count  = local.es_count
  bucket = aws_s3_bucket.es_snapshots[0].id

  rule {
    id     = "abort-incomplete-multipart"
    status = "Enabled"
    filter {}
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# -----------------------------------------------------------------------------
# S3 + KMS policy on the snapshot IRSA role (from C2). Scoped to this bucket +
# the customer CMK (kms:ViaService = s3). The workload permission boundary the
# role carries already permits S3 on pavo-* and KMS on the customer key.
# -----------------------------------------------------------------------------
data "aws_iam_policy_document" "es_snapshots" {
  count = local.es_count

  statement {
    sid       = "S3Bucket"
    effect    = "Allow"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation", "s3:ListBucketMultipartUploads"]
    resources = [aws_s3_bucket.es_snapshots[0].arn]
  }
  statement {
    sid       = "S3Objects"
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:AbortMultipartUpload", "s3:ListMultipartUploadParts"]
    resources = ["${aws_s3_bucket.es_snapshots[0].arn}/*"]
  }
  statement {
    sid       = "KMS"
    effect    = "Allow"
    actions   = ["kms:GenerateDataKey", "kms:Decrypt", "kms:DescribeKey"]
    resources = [data.aws_kms_key.cell_cmk.arn]
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["s3.${var.aws_region}.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "es_snapshots" {
  count = local.es_count

  name   = "snapshot-access"
  role   = aws_iam_role.es_snapshots[0].name
  policy = data.aws_iam_policy_document.es_snapshots[0].json
}

# -----------------------------------------------------------------------------
# One-shot bootstrap Job — registers snapshot repo + _verify + SLM policy
# -----------------------------------------------------------------------------
# Terraform creates the Job (+ mounts the ECK CA and the bootstrap user secret);
# the Job talks to ES. Terraform never calls the ES API and never holds an ES
# credential in state (INV-5). _verify is a provision-time gate: if the backup
# substrate is misconfigured the Job fails and the apply fails, so a cluster
# with no working backups is never silently shipped.
resource "kubernetes_job_v1" "es_bootstrap" {
  count = local.es_count

  metadata {
    name      = "es-bootstrap-${local.es_bootstrap_hash}"
    namespace = local.es_namespace
    labels    = { "pavo.ai/es-client" = "true" }
  }

  spec {
    backoff_limit           = 6
    active_deadline_seconds = 900

    template {
      metadata {
        labels = { "pavo.ai/es-client" = "true" }
      }
      spec {
        restart_policy = "OnFailure"

        container {
          name    = "bootstrap"
          image   = local.es_bootstrap_image
          command = ["sh", "-c", local.es_bootstrap_script]

          env {
            name  = "ES_URL"
            value = "https://${local.es_name}-es-http.${local.es_namespace}.svc:9200"
          }
          env {
            name  = "SNAPSHOT_BUCKET"
            value = local.es_snapshot_bucket
          }
          env {
            name = "USER"
            value_from {
              secret_key_ref {
                name = "es-bootstrap-user"
                key  = "username"
              }
            }
          }
          env {
            name = "PASS"
            value_from {
              secret_key_ref {
                name = "es-bootstrap-user"
                key  = "password"
              }
            }
          }

          volume_mount {
            name       = "es-ca"
            mount_path = "/etc/es-ca"
            read_only  = true
          }
        }

        volume {
          name = "es-ca"
          secret {
            secret_name = "${local.es_name}-es-http-certs-public"
          }
        }
      }
    }
  }

  wait_for_completion = true
  timeouts {
    create = "20m"
    update = "20m"
  }

  depends_on = [
    kubectl_manifest.elasticsearch,
    aws_iam_role_policy.es_snapshots,
    aws_s3_bucket_server_side_encryption_configuration.es_snapshots,
  ]
}
