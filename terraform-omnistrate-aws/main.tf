# -----------------------------------------------------------------------------
# Pavo Infrastructure — AWS (EKS BYOC)
# -----------------------------------------------------------------------------
# Provisions cloud resources for a Pavo deployment on AWS.
# Omnistrate manages the EKS cluster; this module handles:
# - RDS PostgreSQL 16 (Cloud SQL equivalent)
# - ElastiCache Redis ×3 (Memorystore equivalent)
# - S3 buckets ×2 (GCS equivalent)
# - SNS ×2 + SQS ×3 main + SQS ×3 DLQ (Pub/Sub equivalent)
# - EFS (Filestore RWX equivalent) + EBS gp3 StorageClass alias
# - IAM role with IRSA (Workload Identity equivalent)
# - VAPID keys for Web Push notifications (same as GCP module)
# - IngressClass + ClusterIssuer (cluster-scoped, SSA PATCH idempotent)
# -----------------------------------------------------------------------------

# -----------------------------------------------------------------------------
# Data sources — VPC subnets (Omnistrate-provisioned)
# -----------------------------------------------------------------------------

data "aws_subnets" "private" {
  filter {
    name   = "vpc-id"
    values = [var.vpc_id]
  }

  tags = {
    # Omnistrate tags private subnets with this key
    "kubernetes.io/role/internal-elb" = "1"
  }
}

data "aws_vpc" "eks" {
  id = var.vpc_id
}

data "aws_caller_identity" "current" {}

# -----------------------------------------------------------------------------
# Bootstrap-module integration "API"
# These SSM parameters are written by the customer-applied pavo-bootstrap-aws
# module. They carry the ESO IRSA role ARN and the two permission boundaries
# we attach to workload roles.
# -----------------------------------------------------------------------------

data "aws_ssm_parameter" "permission_boundary_arn" {
  name = "/pavo/shared/permission_boundary_arn"
}

# Note: data.aws_ssm_parameter.eso_role_arn and
# data.aws_ssm_parameter.ebs_csi_permission_boundary_arn were removed in PR 2.
# Their consumers (ESO Helm release, ebs_csi IAM role) moved to
# pavo-bootstrap-aws, which owns the cell-scoped K8s/Helm stack.

# Resolve the configured CMK to its underlying key. Two jobs:
#  1. Plan-time validation — the CMK must resolve to a real key the workload role
#     can describe (catches typo'd ARNs, missing keys, and key policies that don't
#     grant DescribeKey), failing early before RDS attempts to use it.
#  2. `.arn` gives the underlying KEY ARN even when cell_kms_key_arn is an ALIAS
#     ARN — required for IAM policy Resource elements, which do NOT authorize
#     crypto actions when scoped to an alias ARN (see elasticsearch_snapshots.tf,
#     zitadel_provision.tf).
data "aws_kms_key" "cell_cmk" {
  key_id = var.cell_kms_key_arn
}

# -----------------------------------------------------------------------------
# Cross-variable validation for identity inputs
# -----------------------------------------------------------------------------
# Terraform <1.9 doesn't allow variable.validation blocks to reference other
# variables, so cross-field checks live here as terraform_data preconditions.
# pavoInfra is `required_version = ">= 1.7"` (not bumped to 1.9 — the runner's
# version isn't guaranteed). If the runner ever pins to 1.9+, these can move
# back to variable.validation blocks for cleaner error placement.
resource "terraform_data" "validate_idp_inputs" {
  lifecycle {
    precondition {
      condition = (
        var.primary_external_identity_provider_enabled == false ||
        trimspace(var.primary_external_identity_provider_type) != ""
      )
      error_message = "primary_external_identity_provider_type is required when primary_external_identity_provider_enabled is true. customer-bootstrap should always emit a non-empty type when the IdP is enabled — check its outputs."
    }

    # saml_idp_id is the truth signal for "this customer uses SAML" (set only
    # by customer-bootstrap when uses_saml is true). The SAML SP URL outputs
    # only fire when saml_idp_id is non-empty; if it's empty but the URLs are
    # set, the customer-bootstrap output contract drifted from pavoInfra's
    # expectations. Catch it here.
    precondition {
      condition = (
        trimspace(var.primary_external_identity_provider_saml_idp_id) != "" ||
        (
          trimspace(var.primary_external_identity_provider_saml_sp_metadata_url) == "" &&
          trimspace(var.primary_external_identity_provider_saml_sp_entity_id) == "" &&
          trimspace(var.primary_external_identity_provider_saml_acs_url) == ""
        )
      )
      error_message = "SAML SP URL apiParameters are non-empty but primary_external_identity_provider_saml_idp_id is empty. customer-bootstrap should set saml_idp_id whenever the SAML SP URLs are non-empty."
    }
  }
}

# -----------------------------------------------------------------------------
# Security Groups
# -----------------------------------------------------------------------------

resource "aws_security_group" "rds" {
  name        = "pavo-rds-sg-${var.instance_id}"
  description = "Allow PostgreSQL access from EKS pods"
  vpc_id      = var.vpc_id

  ingress {
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.eks.cidr_block]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "pavo-rds-sg-${var.instance_id}"
  }
}

resource "aws_security_group" "elasticache" {
  name        = "pavo-ec-sg-${var.instance_id}"
  description = "Allow Redis access from EKS pods"
  vpc_id      = var.vpc_id

  # Scoped to the EKS cluster security group, NOT the VPC CIDR.
  #
  # This security group is the ONLY access control on Redis. The replication
  # groups run with transit_encryption_enabled = false and the account's
  # `default` / no-password user, so anything that can reach port 6379 can read
  # and write Pavo's gateway, intern and onboarding caches in plaintext. With
  # ingress open to the whole VPC CIDR, and that VPC being the CUSTOMER's under
  # BYOC, "anything" included every unrelated resource the customer runs there.
  #
  # The cluster security group is attached to every managed node group instance,
  # and with ENABLE_POD_ENI=false pods inherit the security groups on the node
  # ENIs, so this is the correct handle for "traffic originating from an EKS
  # pod". Verified on an internal test cell: ENABLE_POD_ENI=false,
  # AWS_VPC_K8S_CNI_CUSTOM_NETWORK_CFG=false, zero SecurityGroupPolicy objects,
  # and all 9 running nodes carry the cluster security group.
  #
  # IF SECURITY GROUPS FOR PODS IS EVER ENABLED (ENABLE_POD_ENI=true plus
  # SecurityGroupPolicy objects), pod traffic moves to branch ENIs with their own
  # security groups and this rule stops matching. Re-scope it in the same change
  # that enables that feature.
  #
  # This narrows who can reach Redis; it does not authenticate them. Any pod on
  # the cluster still can. Real authentication needs transit encryption plus an
  # auth token, which is a staged cross-repo migration tracked separately.
  ingress {
    from_port       = 6379
    to_port         = 6379
    protocol        = "tcp"
    security_groups = [data.aws_eks_cluster.primary.vpc_config[0].cluster_security_group_id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "pavo-ec-sg-${var.instance_id}"
  }
}

resource "aws_security_group" "efs" {
  name        = "pavo-efs-sg-${var.instance_id}"
  description = "Allow NFS access from EKS pods"
  vpc_id      = var.vpc_id

  ingress {
    from_port   = 2049
    to_port     = 2049
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.eks.cidr_block]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "pavo-efs-sg-${var.instance_id}"
  }
}

# -----------------------------------------------------------------------------
# RDS PostgreSQL 16 (Multi-AZ)
# -----------------------------------------------------------------------------

resource "aws_db_subnet_group" "pavo" {
  name       = "pavo-db-subnet-${var.instance_id}"
  subnet_ids = data.aws_subnets.private.ids

  tags = {
    Name = "pavo-db-subnet-${var.instance_id}"
  }
}

resource "aws_db_instance" "postgres" {
  identifier            = "pavo-instance-${var.instance_id}"
  engine                = "postgres"
  engine_version        = var.postgres_engine_version
  instance_class        = var.db_instance_class
  allocated_storage     = 20
  max_allocated_storage = 100
  storage_type          = "gp3"
  storage_encrypted     = true
  kms_key_id            = var.cell_kms_key_arn

  db_name                       = "postgres"
  username                      = local.db_username
  manage_master_user_password   = true
  master_user_secret_kms_key_id = var.cell_kms_key_arn

  db_subnet_group_name   = aws_db_subnet_group.pavo.name
  vpc_security_group_ids = [aws_security_group.rds.id]

  multi_az                  = true
  publicly_accessible       = false
  deletion_protection       = var.rds_deletion_protection
  skip_final_snapshot       = !var.create_final_snapshot
  final_snapshot_identifier = var.create_final_snapshot ? "pavo-final-${var.instance_id}" : null

  backup_retention_period = 7
  backup_window           = "03:00-04:00"
  maintenance_window      = "sun:04:00-sun:05:00"

  tags = {
    Name = "pavo-instance-${var.instance_id}"
  }
}

# Wait for RDS to be available before migrations run
resource "time_sleep" "wait_for_rds" {
  depends_on      = [aws_db_instance.postgres]
  create_duration = "120s"
}

# Create databases via a Kubernetes Job — runs inside the EKS cluster so it has
# VPC access to the private RDS endpoint. psql is not available in the Omnistrate
# Terraform execution environment (which runs outside the VPC).
resource "kubernetes_job_v1" "create_databases" {
  depends_on = [
    time_sleep.wait_for_rds,
    kubectl_manifest.external_secret_db_credentials, # waits for ESO sync (Ready=True) before reading the K8s Secret
  ]

  metadata {
    name      = "pavo-init-db-${var.instance_id}"
    namespace = var.instance_id
  }

  spec {
    template {
      metadata {}
      spec {
        container {
          name    = "psql"
          image   = "public.ecr.aws/docker/library/postgres:16-alpine"
          command = ["/bin/sh", "-c"]
          args = [<<-EOT
            for db in pavo-gateway-db pavo-intern-db pavo-onboarding-db pavo-knm-db; do
              psql -tc "SELECT 1 FROM pg_database WHERE datname = '$db'" | grep -q 1 \
                || psql -c "CREATE DATABASE \"$db\""
            done
            echo "All databases ready."
          EOT
          ]
          env {
            name  = "PGHOST"
            value = aws_db_instance.postgres.address
          }
          env {
            name  = "PGPORT"
            value = tostring(aws_db_instance.postgres.port)
          }
          env {
            name = "PGUSER"
            value_from {
              secret_key_ref {
                name = "pavo-rds-db-credentials"
                key  = "username"
              }
            }
          }
          env {
            name = "PGPASSWORD"
            value_from {
              secret_key_ref {
                name = "pavo-rds-db-credentials"
                key  = "password"
              }
            }
          }
          env {
            name  = "PGDATABASE"
            value = "postgres"
          }
        }
        restart_policy = "Never"
      }
    }
    backoff_limit              = 3
    ttl_seconds_after_finished = 300
  }

  wait_for_completion = true

  timeouts {
    create = "10m"
    update = "10m"
  }
}

# -----------------------------------------------------------------------------
# ElastiCache Redis ×3 (cluster mode off = single replication group)
# -----------------------------------------------------------------------------

resource "aws_elasticache_subnet_group" "pavo" {
  name       = "pavo-ec-subnet-${var.instance_id}"
  subnet_ids = data.aws_subnets.private.ids

  tags = {
    Name = "pavo-ec-subnet-${var.instance_id}"
  }
}

resource "aws_elasticache_replication_group" "gateway" {
  replication_group_id = "pavo-gw-redis-${var.instance_id}"
  description          = "Pavo gateway Redis (${var.instance_id})"

  node_type                  = "cache.t3.medium"
  num_cache_clusters         = 1
  engine_version             = "7.1"
  port                       = 6379
  parameter_group_name       = "default.redis7"
  automatic_failover_enabled = false # single node, no failover

  subnet_group_name          = aws_elasticache_subnet_group.pavo.name
  security_group_ids         = [aws_security_group.elasticache.id]
  at_rest_encryption_enabled = true
  transit_encryption_enabled = false # pod-to-Redis within VPC

  tags = {
    Name = "pavo-gw-redis-${var.instance_id}"
  }
}

resource "aws_elasticache_replication_group" "onboarding" {
  replication_group_id = "pavo-onboard-redis-${var.instance_id}"
  description          = "Pavo onboarding Redis (${var.instance_id})"

  node_type                  = "cache.t3.medium"
  num_cache_clusters         = 1
  engine_version             = "7.1"
  port                       = 6379
  parameter_group_name       = "default.redis7"
  automatic_failover_enabled = false

  subnet_group_name          = aws_elasticache_subnet_group.pavo.name
  security_group_ids         = [aws_security_group.elasticache.id]
  at_rest_encryption_enabled = true
  transit_encryption_enabled = false

  tags = {
    Name = "pavo-onboard-redis-${var.instance_id}"
  }

  depends_on = [aws_elasticache_replication_group.gateway]
}

resource "aws_elasticache_replication_group" "intern" {
  replication_group_id = "pavo-intern-redis-${var.instance_id}"
  description          = "Pavo intern Redis (${var.instance_id})"

  node_type                  = "cache.t3.medium"
  num_cache_clusters         = 1
  engine_version             = "7.1"
  port                       = 6379
  parameter_group_name       = "default.redis7"
  automatic_failover_enabled = false

  subnet_group_name          = aws_elasticache_subnet_group.pavo.name
  security_group_ids         = [aws_security_group.elasticache.id]
  at_rest_encryption_enabled = true
  transit_encryption_enabled = false

  tags = {
    Name = "pavo-intern-redis-${var.instance_id}"
  }

  depends_on = [aws_elasticache_replication_group.onboarding]
}

# -----------------------------------------------------------------------------
# S3 Buckets ×2
# -----------------------------------------------------------------------------

locals {
  # Effective public app domain shared by browser-facing infrastructure and
  # the SES sending identity. Custom domains override the standard fallback.
  app_domain = var.app_domain != "" ? var.app_domain : "${var.customer_name}.${var.base_domain}"

  # Browser requests must use the frontend's effective public origin:
  # - Standard BYOC/VPC: local.app_domain falls back to <customer_name>.<base_domain>.
  # - Custom/Plan 2: local.app_domain preserves the configured domain (for example, app.pavoai.com).
  cors_origins = concat(
    ["https://${local.app_domain}", "http://localhost:3000", "http://localhost:5173"],
    var.extra_cors_origins
  )
}

resource "aws_s3_bucket" "onboarding" {
  bucket        = "pavo-${var.customer_name}-onboard-${var.instance_id}"
  force_destroy = var.force_destroy_buckets

  tags = {
    Name = "pavo-${var.customer_name}-onboard-${var.instance_id}"
  }
}

resource "aws_s3_bucket_versioning" "onboarding" {
  bucket = aws_s3_bucket.onboarding.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "onboarding" {
  bucket = aws_s3_bucket.onboarding.id

  rule {
    id     = "retain-live-reap-archived-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days           = 1
      newer_noncurrent_versions = 10
    }
  }

  depends_on = [aws_s3_bucket_versioning.onboarding]
}

resource "aws_s3_bucket_server_side_encryption_configuration" "onboarding" {
  bucket = aws_s3_bucket.onboarding.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = var.cell_kms_key_arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "onboarding" {
  bucket                  = aws_s3_bucket.onboarding.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket" "intern_data" {
  bucket        = "pavo-${var.customer_name}-data-${var.instance_id}"
  force_destroy = var.force_destroy_buckets

  tags = {
    Name = "pavo-${var.customer_name}-data-${var.instance_id}"
  }
}

resource "aws_s3_bucket_versioning" "intern_data" {
  bucket = aws_s3_bucket.intern_data.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "intern_data" {
  bucket = aws_s3_bucket.intern_data.id

  rule {
    id     = "retain-live-reap-archived-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days           = 1
      newer_noncurrent_versions = 10
    }
  }

  depends_on = [aws_s3_bucket_versioning.intern_data]
}

resource "aws_s3_bucket_server_side_encryption_configuration" "intern_data" {
  bucket = aws_s3_bucket.intern_data.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = var.cell_kms_key_arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "intern_data" {
  bucket                  = aws_s3_bucket.intern_data.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# CORS for intern_data bucket (presigned URL access from browser)
resource "aws_s3_bucket_cors_configuration" "intern_data" {
  bucket = aws_s3_bucket.intern_data.id

  cors_rule {
    allowed_headers = ["*"]
    allowed_methods = ["GET", "HEAD", "PUT", "POST", "DELETE"]
    allowed_origins = local.cors_origins
    expose_headers  = ["ETag", "Content-Length", "Content-Type"]
    max_age_seconds = 3600
  }
}

# -----------------------------------------------------------------------------
# SNS Topics ×2 + SQS Queues ×3 main + ×3 DLQ
# -----------------------------------------------------------------------------

# SNS topics
resource "aws_sns_topic" "data_fetcher" {
  name = "pavo-data-fetcher-topic-${var.instance_id}"
  # Same AWS-managed SNS key as connector_sync. Not the cell CMK: SNS→SQS
  # delivery works without extra key-policy grants.
  kms_master_key_id = "alias/aws/sns"

  tags = {
    Name = "pavo-data-fetcher-topic-${var.instance_id}"
  }
}

resource "aws_sns_topic" "dedup" {
  name              = "pavo-dedup-topic-${var.instance_id}"
  kms_master_key_id = "alias/aws/sns"

  tags = {
    Name = "pavo-dedup-topic-${var.instance_id}"
  }
}

# SQS DLQs (must exist before main queues reference them)
resource "aws_sqs_queue" "orch_dlq" {
  name                      = "pavo-orch-dlq-${var.instance_id}"
  message_retention_seconds = 1209600 # 14 days

  tags = {
    Name = "pavo-orch-dlq-${var.instance_id}"
  }
}

resource "aws_sqs_queue" "nugget_dlq" {
  name                      = "pavo-nugget-dlq-${var.instance_id}"
  message_retention_seconds = 1209600

  tags = {
    Name = "pavo-nugget-dlq-${var.instance_id}"
  }
}

resource "aws_sqs_queue" "rag_dlq" {
  name                      = "pavo-rag-dlq-${var.instance_id}"
  message_retention_seconds = 1209600

  tags = {
    Name = "pavo-rag-dlq-${var.instance_id}"
  }
}

# SQS main queues with redrive to DLQs
resource "aws_sqs_queue" "orch" {
  name                       = "pavo-orch-sub-${var.instance_id}"
  visibility_timeout_seconds = 600
  # 7 days — these workers are KEDA scale-to-zero (minReplicas 0), so a wedged-at-0
  # weekend must not lose messages; matches the GCP worker subs' 7-day default and the
  # connector_sync queues. (DLQs already retain 14 days.)
  message_retention_seconds = 604800

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.orch_dlq.arn
    maxReceiveCount     = 5
  })

  tags = {
    Name = "pavo-orch-sub-${var.instance_id}"
  }
}

resource "aws_sqs_queue" "nugget" {
  name                       = "pavo-nugget-sub-${var.instance_id}"
  visibility_timeout_seconds = 600
  message_retention_seconds  = 604800 # 7d, scale-to-zero buffer (see orch above)

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.nugget_dlq.arn
    maxReceiveCount     = 5
  })

  tags = {
    Name = "pavo-nugget-sub-${var.instance_id}"
  }
}

resource "aws_sqs_queue" "rag" {
  name                       = "pavo-rag-sub-${var.instance_id}"
  visibility_timeout_seconds = 600
  message_retention_seconds  = 604800 # 7d, scale-to-zero buffer (see orch above)

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.rag_dlq.arn
    maxReceiveCount     = 5
  })

  tags = {
    Name = "pavo-rag-sub-${var.instance_id}"
  }
}

# SNS → SQS subscriptions
resource "aws_sns_topic_subscription" "orch" {
  topic_arn            = aws_sns_topic.data_fetcher.arn
  protocol             = "sqs"
  endpoint             = aws_sqs_queue.orch.arn
  raw_message_delivery = true
}

resource "aws_sns_topic_subscription" "nugget" {
  topic_arn            = aws_sns_topic.dedup.arn
  protocol             = "sqs"
  endpoint             = aws_sqs_queue.nugget.arn
  raw_message_delivery = true
}

resource "aws_sns_topic_subscription" "rag" {
  topic_arn            = aws_sns_topic.dedup.arn
  protocol             = "sqs"
  endpoint             = aws_sqs_queue.rag.arn
  raw_message_delivery = true
}

# SQS queue policies — allow SNS to deliver messages
resource "aws_sqs_queue_policy" "orch" {
  queue_url = aws_sqs_queue.orch.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "sns.amazonaws.com" }
      Action    = "sqs:SendMessage"
      Resource  = aws_sqs_queue.orch.arn
      Condition = {
        ArnEquals = { "aws:SourceArn" = aws_sns_topic.data_fetcher.arn }
      }
    }]
  })
}

resource "aws_sqs_queue_policy" "nugget" {
  queue_url = aws_sqs_queue.nugget.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "sns.amazonaws.com" }
      Action    = "sqs:SendMessage"
      Resource  = aws_sqs_queue.nugget.arn
      Condition = {
        ArnEquals = { "aws:SourceArn" = aws_sns_topic.dedup.arn }
      }
    }]
  })
}

resource "aws_sqs_queue_policy" "rag" {
  queue_url = aws_sqs_queue.rag.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "sns.amazonaws.com" }
      Action    = "sqs:SendMessage"
      Resource  = aws_sqs_queue.rag.arn
      Condition = {
        ArnEquals = { "aws:SourceArn" = aws_sns_topic.dedup.arn }
      }
    }]
  })
}

# -----------------------------------------------------------------------------
# Connector sync (Phase 2): one SNS topic + one SQS queue per connector type,
# each subscribed with an SNS filter policy on the connector_type message
# attribute so a queue only receives its own type's jobs. Each connector worker
# consumes its queue and scales to zero on backlog (KEDA aws-sqs-queue scaler).
# Mirrors the GCP connector_sync topic + per-type filtered subscriptions.
# Three things MUST stay aligned: (1) this list (and its GCP twin in
# terraform-omnistrate-gcp/main.tf); (2) the app chart's applications.<type> blocks
# (infra-omnistrate/helm/onboarding-copy) whose image repository is the
# onboarding-connector-service image -- the chart derives its connector apps from
# that suffix via onboarding.isConnectorApp in _helpers.tpl; there is no
# connectorTypes list any more; (3) common/pubsub/constants.py CONNECTOR_HANDLING /
# CONNECTOR_TYPES in onboarding-copy. A type enabled in the chart but missing here
# has no queue -> the broker drops every job for that type: on KEDA cells the
# worker simply stays at 0 replicas (silent loss), on non-KEDA/legacy cells it
# CrashLoops on NOT_FOUND; keep all three aligned.
# -----------------------------------------------------------------------------
locals {
  connector_types = [
    "bigquery", "bitbucket", "github", "redash", "metabase", "databricks",
    "superset", "eppo", "statsig", "quicksight", "snowflake", "dbt", "shopify", "intelligems", "powerbi",
    "clickhouse",
  ]
}

resource "aws_sns_topic" "connector_sync" {
  name = "pavo-connector-sync-topic-${var.instance_id}"
  # Encrypt at rest with the AWS-managed SNS CMK (SSE). alias/aws/sns needs no key
  # policy and lets SNS→SQS delivery work without extra grants.
  kms_master_key_id = "alias/aws/sns"
  tags              = { Name = "pavo-connector-sync-topic-${var.instance_id}" }
}

# Shared DLQ for all connector queues.
resource "aws_sqs_queue" "connector_sync_dlq" {
  name                      = "pavo-connector-sync-dlq-${var.instance_id}"
  message_retention_seconds = 1209600 # 14 days
  sqs_managed_sse_enabled   = true    # SSE-SQS (SQS-owned key) at rest
  tags                      = { Name = "pavo-connector-sync-dlq-${var.instance_id}" }
}

# One queue per connector type, with redrive to the shared DLQ.
resource "aws_sqs_queue" "connector_sync" {
  for_each                   = toset(local.connector_types)
  name                       = "pavo-connector-sync-${each.key}-sub-${var.instance_id}"
  visibility_timeout_seconds = 600
  message_retention_seconds  = 604800 # 7 days — parity with GCP connector subs; preserves the scale-to-zero backlog buffer (KEDA wedged at 0 over a weekend must not lose messages)
  sqs_managed_sse_enabled    = true   # SSE-SQS (SQS-owned key) at rest

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.connector_sync_dlq.arn
    maxReceiveCount     = 5
  })

  tags = { Name = "pavo-connector-sync-${each.key}-sub-${var.instance_id}" }
}

# SNS → SQS subscriptions, broker-filtered on the connector_type message
# attribute (set by the SDK SNSPublisher as a String MessageAttribute).
resource "aws_sns_topic_subscription" "connector_sync" {
  for_each             = aws_sqs_queue.connector_sync
  topic_arn            = aws_sns_topic.connector_sync.arn
  protocol             = "sqs"
  endpoint             = each.value.arn
  raw_message_delivery = true
  filter_policy        = jsonencode({ connector_type = [each.key] })
}

# Allow SNS to deliver to each connector queue.
resource "aws_sqs_queue_policy" "connector_sync" {
  for_each  = aws_sqs_queue.connector_sync
  queue_url = each.value.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "sns.amazonaws.com" }
      Action    = "sqs:SendMessage"
      Resource  = each.value.arn
      Condition = {
        ArnEquals = { "aws:SourceArn" = aws_sns_topic.connector_sync.arn }
      }
    }]
  })
}

# -----------------------------------------------------------------------------
# KEDA aws-sqs-queue scaler auth (mirrors the GCP keda-monitoring GSA + WI +
# ClusterTriggerAuthentication added in the canary-amenity PR). The KEDA operator
# is a cluster singleton in the `keda` namespace (installed as a cell amenity);
# its operator KSA is annotated (in the amenity Helm values) with this role's ARN,
# and the scaler reads SQS backlog via that identity. Fixed role name so the
# amenity can reference a stable ARN.
#
# LIFECYCLE: this is a CLUSTER singleton living in a PER-INSTANCE module — the same
# placement as the GCP keda-monitoring GSA. It is safe only under the BYOC model
# where one Omnistrate instance owns the cell (customer = account = cluster): a
# second concurrent instance in the same account would collide on the fixed role
# name, and a per-instance destroy would delete the shared role. The proper home is
# the AWS cell-bootstrap module (pavo-bootstrap-aws), matching the documented GCP
# migration of cluster-scoped resources — tracked as follow-up; kept here for now
# for GCP parity and because the inline policy must reference this instance's queues.
# -----------------------------------------------------------------------------
data "aws_iam_policy_document" "keda_sqs_trust" {
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
      values   = ["system:serviceaccount:keda:keda-operator"]
    }

    condition {
      test     = "StringEquals"
      variable = "${var.eks_oidc_provider}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "keda_sqs" {
  name                 = "keda-sqs-scaler"
  assume_role_policy   = data.aws_iam_policy_document.keda_sqs_trust.json
  permissions_boundary = data.aws_ssm_parameter.permission_boundary_arn.value

  tags = { Name = "keda-sqs-scaler" }
}

# Read-only on the queues KEDA scales: the per-type connector queues + the three
# worker queues (orch/nugget/rag). GetQueueAttributes is all the scaler needs.
data "aws_iam_policy_document" "keda_sqs" {
  statement {
    effect  = "Allow"
    actions = ["sqs:GetQueueAttributes"]
    resources = concat(
      [for q in aws_sqs_queue.connector_sync : q.arn],
      [aws_sqs_queue.orch.arn, aws_sqs_queue.nugget.arn, aws_sqs_queue.rag.arn],
    )
  }
}

resource "aws_iam_role_policy" "keda_sqs" {
  name   = "keda-sqs-read"
  role   = aws_iam_role.keda_sqs.id
  policy = data.aws_iam_policy_document.keda_sqs.json
}

# The ClusterTriggerAuthentication (aws-sqs-queue-auth) that the chart's ScaledObjects
# reference by name is NOT here — it's a cluster-scoped, fixed-name singleton, so it
# lives in the KEDA cell amenity (Pavo's cell-amenity config), created by the keda
# Helm release as a post-install/post-upgrade hook (so it applies after the keda.sh CRDs
# are registered — see that file for why). Keeping it out of per-instance terraform
# removes the cold-cell "CRD not yet installed" apply race. This module owns only the
# AWS IAM identity above (keda-sqs-scaler role + SQS-read policy), which
# podIdentity.provider=aws resolves through the operator's IRSA at runtime.
#
# An earlier revision of this branch created the CTA here as kubectl_manifest. Drop it
# from state WITHOUT destroying the live object (the amenity now owns the same-named
# resource) — same pattern as the cluster-scoped removals elsewhere in this module.
# Safe no-op if it was never in state.
#
# MIGRATION CAVEAT (one-time, only on a cell where the old kubectl_manifest was applied,
# e.g. Pavo's test cell): the live CTA was created by terraform's field-manager with no Helm
# ownership metadata, so the amenity's Helm release can't adopt it and the upgrade
# fails ("invalid ownership metadata"). Before the amenity rolls, either delete it
# (`kubectl delete clustertriggerauthentication aws-sqs-queue-auth`) or label/annotate
# it for Helm adoption (app.kubernetes.io/managed-by=Helm + meta.helm.sh/release-name|
# release-namespace). Fresh cells are unaffected.
removed {
  from = kubectl_manifest.keda_aws_sqs_auth
  lifecycle {
    destroy = false
  }
}

# -----------------------------------------------------------------------------
# EFS (RWX PVCs — Filestore equivalent)
# -----------------------------------------------------------------------------

resource "aws_efs_file_system" "pavo" {
  encrypted = true
  # ForceNew: changing this replaces the filesystem and drops every PVC.
  kms_key_id = var.cell_kms_key_arn

  lifecycle_policy {
    transition_to_ia = "AFTER_30_DAYS"
  }

  tags = {
    Name = "pavo-efs-${var.instance_id}"

    # Required for the EFS CSI driver to create access points on THIS
    # filesystem. Omnistrate owns that driver's role and bounds it with
    # omnistrate-bootstrap-permissions-boundary, whose elasticfilesystem:*
    # statement is conditioned on aws:ResourceTag/omnistrate.com/managed-by =
    # omnistrate. Our StorageClass uses provisioningMode=efs-ap, so every
    # dynamic PVC bind calls CreateAccessPoint against this filesystem; without
    # the tag it sits outside that ceiling and the call is denied at the
    # RESOURCE level, regardless of the driver role's own inline policy. That is
    # why adding an inline policy during a customer onboarding changed
    # nothing. intern-shared and jupyter-worker-shared then hang Pending for the
    # full 30-minute helm wait and intern/exec-runner fail to converge.
    #
    # Confirmed with Omnistrate (Alok, 2026-08-29) as the INTENDED pattern for a
    # filesystem the service provider creates itself. On the delete-exposure
    # question: the tag does widen what the dataplane agent COULD do
    # (elasticfilesystem:* on tag-matched resources, so DeleteFileSystem
    # simulates from implicitDeny to allowed), but Omnistrate confirmed the
    # agent only acts on filesystems their platform creates from the spec and
    # "doesn't include any externally managed filesystem resources even if they
    # are tagged". The capability exists; it is not exercised.
    #
    # Same pattern as scripts/create-cmk.sh tagging the Pavo-owned CMK
    # omnistrate.com/customer-managed-kms=true so Omnistrate's EBS CSI role may
    # use it. Tagging satisfies an Omnistrate role's IAM condition; it does not
    # transfer ownership. This module still creates and destroys the filesystem.
    #
    # RESOURCE-LEVEL ONLY. Never move this to provider default_tags: that would
    # stamp every Pavo AWS resource as Omnistrate-managed. It also must not
    # displace managed_by=pavo (which arrives via default_tags, a different key,
    # so there is no collision) — our own runner boundary scopes every EFS
    # mutation on aws:ResourceTag/managed_by=pavo, and losing it would lock the
    # runner out of its own filesystem, including out of re-tagging it.
    "omnistrate.com/managed-by" = "omnistrate"
  }
}

resource "aws_efs_mount_target" "pavo" {
  for_each = toset(data.aws_subnets.private.ids)

  file_system_id  = aws_efs_file_system.pavo.id
  subnet_id       = each.value
  security_groups = [aws_security_group.efs.id]
}

# -----------------------------------------------------------------------------
# IAM Role with IRSA (Workload Identity equivalent)
# One shared role for all KSAs in the namespace — Phase 1
# -----------------------------------------------------------------------------

data "aws_iam_policy_document" "irsa_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/${var.eks_oidc_provider}"]
    }

    condition {
      test     = "StringLike"
      variable = "${var.eks_oidc_provider}:sub"
      # Allow any KSA in the instance namespace
      values = ["system:serviceaccount:${var.instance_id}:*"]
    }

    condition {
      test     = "StringEquals"
      variable = "${var.eks_oidc_provider}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "pavo" {
  name                 = "pavo-role-${var.instance_id}"
  assume_role_policy   = data.aws_iam_policy_document.irsa_trust.json
  permissions_boundary = data.aws_ssm_parameter.permission_boundary_arn.value

  tags = {
    Name = "pavo-role-${var.instance_id}"
  }
}

data "aws_iam_policy_document" "pavo_permissions" {
  # S3
  statement {
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:GetObjectVersion",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:ListBucket",
    ]
    resources = [
      aws_s3_bucket.onboarding.arn,
      "${aws_s3_bucket.onboarding.arn}/*",
      aws_s3_bucket.intern_data.arn,
      "${aws_s3_bucket.intern_data.arn}/*",
    ]
  }

  # Cell CMK for the application buckets (sse_algorithm = aws:kms). Without
  # this, PutObject/GetObject fail after the bucket default flips off SSE-S3.
  # EFS at-rest crypto is the EFS service's; the app never calls KMS for it.
  statement {
    effect = "Allow"
    actions = [
      "kms:Decrypt",
      "kms:Encrypt",
      "kms:GenerateDataKey",
      "kms:DescribeKey",
    ]
    resources = [data.aws_kms_key.cell_cmk.arn]
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["s3.${var.aws_region}.amazonaws.com"]
    }
  }

  # SNS publish
  statement {
    effect  = "Allow"
    actions = ["sns:Publish"]
    resources = [
      aws_sns_topic.data_fetcher.arn,
      aws_sns_topic.dedup.arn,
      # connector_sync: the orchestrator dispatcher publishes connector jobs here
      # (attribute-routed to the per-type queues). Without this, dispatch fails AccessDenied.
      aws_sns_topic.connector_sync.arn,
    ]
  }

  # SQS receive/delete/visibility
  statement {
    effect = "Allow"
    actions = [
      "sqs:ReceiveMessage",
      "sqs:DeleteMessage",
      "sqs:ChangeMessageVisibility",
      "sqs:GetQueueAttributes",
    ]
    resources = concat(
      [
        aws_sqs_queue.orch.arn,
        aws_sqs_queue.nugget.arn,
        aws_sqs_queue.rag.arn,
        aws_sqs_queue.orch_dlq.arn,
        aws_sqs_queue.nugget_dlq.arn,
        aws_sqs_queue.rag_dlq.arn,
        aws_sqs_queue.connector_sync_dlq.arn,
      ],
      # connector workers consume their per-type queue; without these the
      # subscriber can't ReceiveMessage and no connector job is ever processed.
      [for q in aws_sqs_queue.connector_sync : q.arn],
    )
  }

  # Bedrock LLM inference — scoped to specific model ARNs (least-privilege;
  # if the model changes, this policy must update in the same PR as BEDROCK_MODEL)
  # Cross-region inference profiles (us.*) internally route to any US region (us-east-1,
  # us-east-2, us-west-2). The IAM check fires at the destination, so foundation-model ARNs
  # must use a wildcard region; the inference-profile ARN itself stays region-scoped.
  #
  # Titan Text Embeddings V2 backs the tribal query-service embedding path
  # (EMBEDDING_PROVIDER=bedrock, spec `embeddingDefaultModel`) via the
  # pavo-platform-sdk. It is invoked directly as a foundation model (no
  # cross-region inference profile) and, being AWS first-party, needs no
  # marketplace model-use agreement. Same rule as above: if
  # embeddingDefaultModel changes, update this ARN in the same PR.
  statement {
    effect  = "Allow"
    actions = ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"]
    resources = [
      "arn:aws:bedrock:*::foundation-model/anthropic.claude-sonnet-4-6",
      "arn:aws:bedrock:${var.aws_region}:${data.aws_caller_identity.current.account_id}:inference-profile/us.anthropic.claude-sonnet-4-6",
      "arn:aws:bedrock:*::foundation-model/anthropic.claude-opus-4-6-v1",
      "arn:aws:bedrock:${var.aws_region}:${data.aws_caller_identity.current.account_id}:inference-profile/us.anthropic.claude-opus-4-6-v1",
      "arn:aws:bedrock:*::foundation-model/amazon.titan-embed-text-v2:0",
    ]
  }

  # RDS IAM auth
  statement {
    effect    = "Allow"
    actions   = ["rds-db:connect"]
    resources = ["arn:aws:rds-db:${var.aws_region}:${data.aws_caller_identity.current.account_id}:dbuser:${aws_db_instance.postgres.resource_id}/${local.db_username}"]
  }

  # NOTE: there is deliberately NO `elasticache:Connect` statement here, unlike
  # the `rds-db:connect` grant above. ElastiCache IAM authentication requires
  # transit encryption AND an ElastiCache user with AuthenticationMode `iam`.
  # These replication groups set `transit_encryption_enabled = false` and use
  # the account's `default` / no-password user with no user groups, so Redis
  # accepts unauthenticated connections and no client ever signs an
  # `elasticache:Connect` request. The grant existed from the module's first
  # commit alongside that same `transit_encryption_enabled = false`, so it was
  # never functional — it only made Redis access look IAM-gated when the sole
  # control is `aws_security_group.elasticache`.
  # Re-add this (and the matching boundary statement in
  # pavo-bootstrap-aws/policy-statements.json) only when ALL THREE hold:
  #   1. transit_encryption_enabled = true on the replication groups
  #   2. an ElastiCache user with AuthenticationMode `iam`, in a user group
  #      attached to those replication groups
  #   3. the CLIENTS actually use it — api-gateway, intern and onboarding-copy
  #      connecting over rediss:// with IAM-signed auth
  # The third is the one that gets forgotten, and it is what makes the grant
  # meaningful rather than merely permitted: infrastructure can satisfy 1 and 2
  # while every client still opens a plaintext unauthenticated connection, which
  # is exactly the state that made this grant dead for its whole life.
  # scripts/simulate-policy.py carries the same three-part gate; keep them in
  # step.

  # SES SendEmail for api-gateway transactional email (email_enabled only),
  # scoped to THIS instance's sending identity and its From address.
  dynamic "statement" {
    for_each = local.email_enabled ? [1] : []
    content {
      effect    = "Allow"
      actions   = ["ses:SendEmail"]
      resources = [aws_sesv2_email_identity.sending_domain[0].arn]
      condition {
        test     = "StringEquals"
        variable = "ses:FromAddress"
        values   = ["noreply@${local.app_domain}"]
      }
    }
  }
}

resource "aws_iam_role_policy" "pavo" {
  name   = "pavo-policy-${var.instance_id}"
  role   = aws_iam_role.pavo.id
  policy = data.aws_iam_policy_document.pavo_permissions.json
}

# -----------------------------------------------------------------------------
# Bedrock model access bootstrap
# -----------------------------------------------------------------------------
# Anthropic models require an AWS Marketplace agreement before first invocation.
# This runs once per account+region at provisioning time, making models available
# immediately when pods start. Idempotent — existing agreements are skipped.

resource "terraform_data" "bedrock_model_agreements" {
  triggers_replace = [var.aws_region]

  provisioner "local-exec" {
    # Best-effort: the provisioning role intentionally holds no Bedrock agreement
    # permissions (Option B / least-privilege), so these `aws bedrock` calls fail
    # with AccessDenied; on_failure = continue keeps that from aborting the whole
    # apply. The customer enables Bedrock model access once during onboarding, and
    # it's verified separately during onboarding readiness.
    on_failure  = continue
    interpreter = ["/bin/sh", "-ec"]
    command     = <<-EOT
      for MODEL_ID in \
        "anthropic.claude-sonnet-4-6" \
        "anthropic.claude-opus-4-6-v1"; do

        echo "Enabling Bedrock model: $MODEL_ID in ${var.aws_region}"

        OFFER_TOKEN=$(aws bedrock list-foundation-model-agreement-offers \
          --region "${var.aws_region}" \
          --model-id "$MODEL_ID" \
          --query 'offers[0].offerToken' \
          --output text 2>/dev/null)

        if [ -z "$OFFER_TOKEN" ] || [ "$OFFER_TOKEN" = "None" ]; then
          echo "No offer token for $MODEL_ID — skipping"
          continue
        fi

        aws bedrock create-foundation-model-agreement \
          --region "${var.aws_region}" \
          --model-id "$MODEL_ID" \
          --offer-token "$OFFER_TOKEN" 2>/dev/null || \
          echo "Agreement for $MODEL_ID already exists — skipping"

        echo "Model $MODEL_ID enabled."
      done
    EOT
  }
}

# Note: the EKS access entry that grants the Omnistrate runner cluster-admin
# RBAC, along with `data.aws_iam_session_context.current` and
# `time_sleep.wait_for_eks_access`, moved to pavo-bootstrap-aws in PR 2. The
# runner's access entry is now created once per cell at bootstrap time.

# -----------------------------------------------------------------------------
# Instance namespace — apps + the create-databases Job + the ExternalSecret
# all live here. SSA-applied so we don't conflict with Omnistrate's Helm
# runtime if it also creates the namespace. Carries the
# `policy.sigstore.dev/include = "true"` label — the cluster-wide Sigstore
# Policy Controller (owned by pavo-bootstrap-aws) picks up labeled namespaces
# dynamically. Defined below in the same file.
# -----------------------------------------------------------------------------

# -----------------------------------------------------------------------------
# ExternalSecrets — per-instance ClusterSecretStore + ExternalSecret
# -----------------------------------------------------------------------------
# The ESO controller itself + the ESO IRSA role + the CRDs all moved to
# pavo-bootstrap-aws (cell-scoped — one ESO install per cluster). What remains
# here is the per-instance plumbing: a ClusterSecretStore named for this
# instance (so multi-tenant clusters don't collide) and the ExternalSecret
# that syncs the RDS master password into a K8s Secret in the instance
# namespace.

resource "kubectl_manifest" "eso_cluster_secret_store" {
  yaml_body         = <<-YAML
    apiVersion: external-secrets.io/v1beta1
    kind: ClusterSecretStore
    metadata:
      name: pavo-aws-sm-${var.instance_id}
    spec:
      provider:
        aws:
          service: SecretsManager
          region: ${var.aws_region}
          auth:
            jwt:
              serviceAccountRef:
                name: external-secrets
                namespace: external-secrets
  YAML
  server_side_apply = true
  force_conflicts   = true
}

# ExternalSecret syncs username + password from the RDS-managed Secrets Manager
# secret, and uses Terraform-provided host/port (NOT pulled from SM, since the
# value-schema of RDS-managed secrets beyond {username, password} is not part
# of the AWS contract). Composes per-database DATABASE_URL_* connection strings
# via Sprig's urlquery filter (engineVersion: v2).
#
# wait_for blocks Terraform until ESO marks the resource Ready=True. value_type
# "eq" means literal-equality match against the JSONPath value (verified via
# `terraform validate` against alekc/kubectl 2.2.0 schema during planning).
# external_secret_db_credentials uses `kubectl_manifest` (alekc/kubectl).
#
# PR #118 swapped this to `kubernetes_manifest` (hashicorp/kubernetes) to avoid
# the SSA-normalization diff loop, but that provider does a plan-time OpenAPI
# schema lookup for the GVK and reliably errored on the Omnistrate runner with
#
#   Error: API did not recognize GroupVersionKind from manifest
#   (CRD may not be installed)
#
# even with: ESO CRDs installed (v1beta1 served+storage), RBAC cluster-admin,
# namespace existing, OpenAPI v2+v3 listing v1beta1.ExternalSecret, and adjacent
# `kubectl_manifest` resources working on the exact same runner. Likely a
# hashicorp/kubernetes 2.30.x OpenAPI-cache quirk on the per-instance runner pods;
# see follow-up investigation tracked separately.
#
# So we're back on `kubectl_manifest` with the original SSA-diff-loop guard:
# `lifecycle { ignore_changes = [yaml_body] }` suppresses the loop where alekc/kubectl
# sees ESO-controller-mutated fields as drift and tries destroy/recreate every plan
# (the wedge that hit an internal test instance). Intentional manifest updates require:
#   terraform apply -replace=kubectl_manifest.external_secret_db_credentials
resource "kubectl_manifest" "external_secret_db_credentials" {
  yaml_body         = <<-YAML
    apiVersion: external-secrets.io/v1beta1
    kind: ExternalSecret
    metadata:
      name: pavo-rds-db-credentials
      namespace: ${var.instance_id}
    spec:
      refreshInterval: 5m
      secretStoreRef:
        name: pavo-aws-sm-${var.instance_id}
        kind: ClusterSecretStore
      target:
        name: pavo-rds-db-credentials
        creationPolicy: Owner
        template:
          engineVersion: v2
          data:
            password: "{{ .password }}"
            username: "{{ .username }}"
            host: "${aws_db_instance.postgres.address}"
            port: "${aws_db_instance.postgres.port}"
            # ---------------------------------------------------------------
            # Per-database DATABASE_URL_* keys.
            #
            # SQLAlchemy's async engine (`create_async_engine`) and sync
            # engine (`create_engine`) reject each other's URL prefix —
            # `postgresql+asyncpg://` only works with async, `postgresql://`
            # only works with sync. Each Pavo service runs Alembic migrations
            # (sync) AND the main app (async) against the same database, so we
            # publish BOTH variants here and let each consumer pick.
            #
            #   bare name (e.g. DATABASE_URL_GATEWAY) → postgresql+asyncpg://,
            #     consumed by main containers (api-gateway, onboarding-copy,
            #     tribal-knowledge).
            #   _SYNC suffix                         → postgresql://,
            #     consumed by Alembic migration jobs / initContainers.
            #
            # intern is special: its app code rewrites the prefix internally
            # (src/app/db/session.py:_to_asyncpg_url + src/init_intern_db.py),
            # AND it has sync engines in src/temporal/worker.py and the
            # sessionmaker. Both contexts in intern consume DATABASE_URL_INTERN
            # which must be sync; there is intentionally no
            # DATABASE_URL_INTERN_SYNC because nothing reads it.
            # ---------------------------------------------------------------
            DATABASE_URL_GATEWAY:         "postgresql+asyncpg://{{ .username }}:{{ .password | urlquery }}@${aws_db_instance.postgres.address}:${aws_db_instance.postgres.port}/pavo-gateway-db"
            DATABASE_URL_GATEWAY_SYNC:    "postgresql://{{ .username }}:{{ .password | urlquery }}@${aws_db_instance.postgres.address}:${aws_db_instance.postgres.port}/pavo-gateway-db"
            DATABASE_URL_INTERN:          "postgresql://{{ .username }}:{{ .password | urlquery }}@${aws_db_instance.postgres.address}:${aws_db_instance.postgres.port}/pavo-intern-db"
            DATABASE_URL_ONBOARDING:      "postgresql+asyncpg://{{ .username }}:{{ .password | urlquery }}@${aws_db_instance.postgres.address}:${aws_db_instance.postgres.port}/pavo-onboarding-db"
            DATABASE_URL_ONBOARDING_SYNC: "postgresql://{{ .username }}:{{ .password | urlquery }}@${aws_db_instance.postgres.address}:${aws_db_instance.postgres.port}/pavo-onboarding-db"
            DATABASE_URL_KNM:             "postgresql+asyncpg://{{ .username }}:{{ .password | urlquery }}@${aws_db_instance.postgres.address}:${aws_db_instance.postgres.port}/pavo-knm-db"
            DATABASE_URL_KNM_SYNC:        "postgresql://{{ .username }}:{{ .password | urlquery }}@${aws_db_instance.postgres.address}:${aws_db_instance.postgres.port}/pavo-knm-db"
      data:
        - secretKey: password
          remoteRef:
            key: ${aws_db_instance.postgres.master_user_secret[0].secret_arn}
            property: password
        - secretKey: username
          remoteRef:
            key: ${aws_db_instance.postgres.master_user_secret[0].secret_arn}
            property: username
  YAML
  server_side_apply = true
  force_conflicts   = true

  wait_for {
    field {
      key   = "status.conditions.[0].type"
      value = "Ready"
    }
    field {
      key   = "status.conditions.[0].status"
      value = "True"
    }
  }

  timeouts {
    create = "5m"
  }

  lifecycle {
    # alekc/kubectl's SSA-normalization sees ESO-controller-mutated fields in
    # the live object as drift and tries to destroy/recreate every plan.
    # Suppressing yaml_body drift breaks the loop. Intentional non-RDS updates
    # to the body still require:
    #   terraform apply -replace=kubectl_manifest.external_secret_db_credentials
    ignore_changes = [yaml_body]
    # ignore_changes also masks real RDS replacement (address/port/secret_arn)
    # because yaml_body embeds those values. replace_triggered_by forces this
    # manifest to be replaced whenever aws_db_instance.postgres replaces, so
    # the ExternalSecret stays in sync with the live RDS instance.
    replace_triggered_by = [aws_db_instance.postgres]
  }

  depends_on = [
    kubectl_manifest.eso_cluster_secret_store,
    kubectl_manifest.instance_namespace,
    aws_db_instance.postgres,
  ]
}

# Note: Stakater Reloader Helm release moved to pavo-bootstrap-aws in PR 2
# (cell-scoped — one Reloader install per cluster).

# Note: the EBS CSI driver IRSA stack (IAM role, role-policy attachment, SA
# annotation, ebs-csi-leases Role + RoleBinding, ebs_gp3 / pd-balanced
# StorageClass), plus the pavo-nginx IngressClass and pavo-letsencrypt-prod
# ClusterIssuer, all moved to pavo-bootstrap-aws in PR 2. These are inherently
# per-cell (cluster-scoped K8s objects + cluster-OIDC-bound IAM roles), and
# the previous per-instance ownership was the lifecycle bug that broke EBS
# IRSA for every other instance on the cluster whenever any single instance
# was destroyed. See plan section "Resource scoping matrix" / "EBS CSI
# special handling" for the full story.

# -----------------------------------------------------------------------------
# EFS StorageClass (per-instance — name includes var.instance_id)
# -----------------------------------------------------------------------------

resource "kubernetes_storage_class_v1" "efs_pavo" {
  metadata {
    name = "efs-pavo-vpc-${var.instance_id}"
  }

  storage_provisioner    = "efs.csi.aws.com"
  reclaim_policy         = "Delete"
  volume_binding_mode    = "Immediate"
  allow_volume_expansion = true

  parameters = {
    provisioningMode = "efs-ap"
    fileSystemId     = aws_efs_file_system.pavo.id
    directoryPerms   = "700"
    uid              = "1000" # Must match securityContext.runAsUser in onboarding-copy Helm charts and useradd UID in connector_services/Dockerfile
    gid              = "1000"
  }

  depends_on = [aws_efs_mount_target.pavo]
}

# -----------------------------------------------------------------------------
# Sigstore Policy Controller — cluster-scoped image signature + attestation
# enforcement
# -----------------------------------------------------------------------------
# (See terraform-omnistrate-gcp/main.tf for the full design + rationale.
# Post-rescope (PRs #115/#118), the EKS access entry that the Omnistrate
# Terraform runner needs is created by pavo-bootstrap-aws BEFORE the first
# pavoInfra apply — so the previous `time_sleep.wait_for_eks_access` guard
# is no longer needed in this module.)

resource "kubectl_manifest" "instance_namespace" {
  server_side_apply = true
  force_conflicts   = true
  field_manager     = "terraform"
  apply_only        = true # NEVER delete on teardown — namespace may be reused by Omnistrate Helm / app lifecycle

  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "Namespace"
    metadata = {
      name = var.instance_id
      # Per-instance opt-in label for the Sigstore Policy Controller. The
      # controller itself + ClusterImagePolicy objects are cell-scoped and
      # owned by pavo-bootstrap-aws. The controller picks up labeled
      # namespaces dynamically, so no Terraform-graph dependency is needed
      # here. Operational invariant: pavo-bootstrap-aws MUST be applied
      # before pavoInfra workloads are expected to be policy-enforced.
      labels = {
        "policy.sigstore.dev/include" = "true"
      }
    }
  })
}

resource "kubernetes_secret_v1" "intern_sandbox_gcsfuse_key" {
  count = var.sandbox_gcsfuse_enabled && trimspace(var.sandbox_gcsfuse_key_json) != "" ? 1 : 0

  metadata {
    name      = "pavo-intern-sandbox-gcsfuse-key"
    namespace = var.instance_id
  }

  type = "Opaque"

  data = {
    "key.json" = var.sandbox_gcsfuse_key_json
  }

  depends_on = [kubectl_manifest.instance_namespace]
}

# ghcr.io read credential for the cell's Sigstore policy-controller. Under
# enforce, the controller fetches cosign signatures/attestations from the
# PRIVATE ghcr.io/pavoai/* repos to verify images; without creds it gets 401 and
# denies every pavoai image. signaturePullSecrets resolve from the ADMITTED
# workload's namespace (not cosign-system), so this per-instance-namespace
# secret is what each ClusterImagePolicy authority references by name
# (pavo-ghcr-signature-pull) in pavo-bootstrap-aws. Reuses $secret.ghcr_dockerconfig
# — the same org credential the service charts already use for image pulls.
resource "kubernetes_secret_v1" "ghcr_signature_pull" {
  count = trimspace(var.ghcr_dockerconfig) != "" ? 1 : 0

  metadata {
    name      = "pavo-ghcr-signature-pull"
    namespace = var.instance_id
  }

  type = "kubernetes.io/dockerconfigjson"

  # $secret.ghcr_dockerconfig is ALREADY base64-encoded (that's how the service
  # Helm charts consume it). `data` would base64-encode it AGAIN — k8s then
  # decodes once and rejects the still-base64 string ("invalid character 'e'").
  # `binary_data` stores the already-base64 value as-is, which is what a Secret's
  # data field holds.
  binary_data = {
    ".dockerconfigjson" = var.ghcr_dockerconfig
  }

  depends_on = [kubectl_manifest.instance_namespace]
}

# -----------------------------------------------------------------------------
# Elasticsearch (Elastic Cloud — AWS Marketplace org)
# -----------------------------------------------------------------------------

resource "ec_deployment" "onboarding_es" {
  # es_mode = "cloud" (default) provisions Elastic Cloud; "self_hosted" skips it
  # (the in-VPC ECK cluster in elasticsearch_self_hosted.tf serves ES instead).
  count = var.es_mode == "cloud" ? 1 : 0

  name                   = "pavo-${var.customer_name}-es-${var.instance_id}"
  region                 = "aws-${var.elastic_cloud_region}"
  version                = "8.19.5"
  deployment_template_id = "aws-general-purpose"

  elasticsearch = {
    hot = {
      size       = "1g"
      zone_count = 1
      autoscaling = {
        min_size          = "1g"
        max_size          = "4g"
        min_size_resource = "storage"
        max_size_resource = "storage"
      }
    }
  }

  kibana = {
    size       = "1g"
    zone_count = 1
  }
}

# Adding count to the pre-existing ec_deployment changes its address
# (onboarding_es -> onboarding_es[0]). This keeps already-applied cloud instances
# mapped to [0] so they are NOT destroyed/recreated on apply.
moved {
  from = ec_deployment.onboarding_es
  to   = ec_deployment.onboarding_es[0]
}

# app_api_key likewise gained a count (cloud-only). Map the pre-existing
# singleton to [0] so already-applied cloud instances keep their key instead of
# planning a destroy/create, which would rotate the exported elasticsearch_api_key.
moved {
  from = elasticstack_elasticsearch_security_api_key.app_api_key
  to   = elasticstack_elasticsearch_security_api_key.app_api_key[0]
}

resource "elasticstack_elasticsearch_security_api_key" "app_api_key" {
  count = var.es_mode == "cloud" && var.elasticsearch_api_key == "" ? 1 : 0

  name = "pavo-es-api-key"

  role_descriptors = jsonencode({
    app_access = {
      cluster = ["monitor"]
      indices = [{
        names      = ["*"]
        privileges = ["all"]
      }]
    }
  })

  # Explicit ordering: create ec_deployment before this key; destroy this key
  # before ec_deployment. The provider's connection (providers.tf) also derives
  # from ec_deployment, so dependency-order-wise both are aligned.
  depends_on = [ec_deployment.onboarding_es]
}

# -----------------------------------------------------------------------------
# VAPID Keys (Web Push notifications — cloud-agnostic)
# -----------------------------------------------------------------------------

resource "tls_private_key" "vapid" {
  algorithm   = "ECDSA"
  ecdsa_curve = "P256"
}

# -----------------------------------------------------------------------------
# Auto-generated Secrets
# -----------------------------------------------------------------------------

resource "random_password" "capability_token_secret" {
  length  = 64
  special = false
}

resource "random_password" "worker_api_secret" {
  length  = 64
  special = false
}

# -----------------------------------------------------------------------------
# State migration shims: forget pre-rescope zitadel_* resources from state.
# -----------------------------------------------------------------------------
# PR #118 (3aacddd) moved the 9 zitadel_* resources out of pavoInfra and into
# pavo-customer-bootstrap, AND removed the `provider "zitadel" {}` block from
# providers.tf. Instances created before that change (for example one created
# 2026-05-20) still carry those resources in their pavoInfra terraform state.
# When pavoInfra plans against that state without a declared zitadel provider,
# Terraform synthesizes an empty `provider["registry.opentofu.org/zitadel/zitadel"]`
# and the plan fails:
#
#   Error: Missing required attribute
#     on provider["registry.opentofu.org/zitadel/zitadel"] with no configuration
#   The attribute "domain" is required, but no definition was found.
#
# The `removed` blocks below tell Terraform to drop the resources from state
# WITHOUT invoking the provider to destroy the cloud objects. This is correct:
# pavo-customer-bootstrap now owns these objects in Pavo's Zitadel tenant
# (imported into customer-bootstrap state in Phase 1 of the rescope); destroying
# them from pavoInfra would break the customer-bootstrap ownership.
#
# IMPORTANT: `from` MUST omit instance keys like `[0]` — Terraform matches the
# block against every instance of the resource address. Including `[0]` is a
# documented syntax error.
#
# Removal: keep these blocks until every pre-#118 pavoInfra state has been
# planned at least once against this code (state entries get cleared on the
# first successful plan that processes the `removed` block). After every
# pre-#118 instance reaches RUNNING on this version, drop these in a
# cleanup PR. Until then they are no-ops on fresh states.
# -----------------------------------------------------------------------------

removed {
  from = zitadel_org.customer
  lifecycle {
    destroy = false
  }
}

removed {
  from = zitadel_project.pavo
  lifecycle {
    destroy = false
  }
}

removed {
  from = zitadel_application_oidc.pavo_web
  lifecycle {
    destroy = false
  }
}

removed {
  from = zitadel_org_idp_google.primary_external_identity_provider
  lifecycle {
    destroy = false
  }
}

removed {
  from = zitadel_org_idp_oidc.primary_external_identity_provider
  lifecycle {
    destroy = false
  }
}

removed {
  from = zitadel_org_idp_saml.primary_external_identity_provider
  lifecycle {
    destroy = false
  }
}

removed {
  from = zitadel_action.prefill_saml_register
  lifecycle {
    destroy = false
  }
}

removed {
  from = zitadel_trigger_actions.prefill_saml_register
  lifecycle {
    destroy = false
  }
}

removed {
  from = zitadel_login_policy.primary_external_identity_provider
  lifecycle {
    destroy = false
  }
}

# -----------------------------------------------------------------------------
# State migration shims: forget Sigstore cluster-scoped resources from state.
# -----------------------------------------------------------------------------
# PR #90 briefly placed `helm_release.policy_controller` and
# `kubectl_manifest.pavo_image_policy` (per-service ClusterImagePolicy) here.
# These are cluster-scoped — they belong in `pavo-bootstrap-aws/` per the
# ownership rule (no cluster-scoped K8s resource may live in pavoInfra). They
# were moved out by this PR.
#
# In practice every post-#90 pavoInfra apply failed at plan time on a broken
# `file("${path.module}/../spec/image-manifest.json")` in a `locals` block,
# which evaluates BEFORE any resource is reconciled — so the resources never
# actually got created and state should be clean. These blocks are belt-and-
# suspenders: if some plan slipped through and got the resources into state,
# the `removed { lifecycle { destroy = false } }` form drops them without
# destroying the cluster-wide policy resources (now owned by bootstrap).
#
# Removal: keep until every pavoInfra state has been planned at least once
# against this code. Safe to drop in a cleanup PR once every existing instance
# re-reaches RUNNING on this version.
# -----------------------------------------------------------------------------

removed {
  from = helm_release.policy_controller
  lifecycle {
    destroy = false
  }
}

removed {
  from = kubectl_manifest.pavo_image_policy
  lifecycle {
    destroy = false
  }
}
