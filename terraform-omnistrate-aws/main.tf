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
# module. This module reads only the workload permission boundary it attaches
# to workload roles.
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
  # Until redis_security_phase = enforced, plaintext or token-less clients are
  # accepted, so this security group is the effective access control on Redis.
  # With ingress open to the whole VPC CIDR, and that VPC being the CUSTOMER's
  # under BYOC, every unrelated resource they run could reach it.
  #
  # The cluster security group is attached to every managed node group instance,
  # and with ENABLE_POD_ENI=false pods inherit the security groups on the node
  # ENIs, so this is the correct handle for "traffic originating from an EKS
  # pod". Verified on a live cell: ENABLE_POD_ENI=false,
  # AWS_VPC_K8S_CNI_CUSTOM_NETWORK_CFG=false, zero SecurityGroupPolicy objects,
  # and all 9 running nodes carry the cluster security group.
  #
  # IF SECURITY GROUPS FOR PODS IS EVER ENABLED (ENABLE_POD_ENI=true plus
  # SecurityGroupPolicy objects), pod traffic moves to branch ENIs with their own
  # security groups and this rule stops matching. Re-scope it in the same change
  # that enables that feature.
  #
  # This narrows who can reach Redis; authentication is the AUTH token on the
  # replication groups below.
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

  # Cluster SG, not VPC CIDR: other hosts in the customer VPC must not reach NFS.
  # Same node-ENI assumptions as aws_security_group.elasticache above.
  ingress {
    from_port       = 2049
    to_port         = 2049
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
          image   = local.image.postgres_16_alpine
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

# redis_security_phase: AWS forbids skipping steps on an existing group (TLS
# preferred before required; token ROTATE (optional) before SET (required)).
# The provider applies the transit change, waits, then the token change.
# apply_immediately: else the transit change may defer to the maintenance window
# while the token modify (always immediate) needs TLS already on.
locals {
  redis_phase_index    = index(["off", "tls_preferred", "tls_required", "enforced"], var.redis_security_phase)
  redis_tls            = local.redis_phase_index >= 1
  redis_auth           = local.redis_phase_index >= 2 # AWS rejects a token with TLS preferred
  redis_tls_mode       = local.redis_tls ? (local.redis_auth ? "required" : "preferred") : null
  redis_token_strategy = local.redis_auth ? (var.redis_security_phase == "enforced" ? "SET" : "ROTATE") : null
}

# ElastiCache allows only (!&#$^<>-) as specials; alphanumeric keeps URLs unescaped.
resource "random_password" "redis_auth" {
  for_each = toset(["gateway", "intern", "onboarding"])
  length   = 64
  special  = false
}

# Consumed by the app charts via secretKeyRef (spec aws-values: redis.authSecretName/Key).
resource "kubernetes_secret_v1" "redis_auth" {
  metadata {
    name      = "pavo-redis-auth"
    namespace = var.instance_id
  }

  data = { for k, v in random_password.redis_auth : k => v.result }

  depends_on = [kubectl_manifest.instance_namespace]
}

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

  node_type                  = var.redis_node_type
  num_cache_clusters         = 1
  engine_version             = "7.1"
  port                       = 6379
  parameter_group_name       = "default.redis7"
  automatic_failover_enabled = false # single node, no failover

  subnet_group_name          = aws_elasticache_subnet_group.pavo.name
  security_group_ids         = [aws_security_group.elasticache.id]
  at_rest_encryption_enabled = true
  kms_key_id                 = data.aws_kms_key.cell_cmk.arn
  # Key change forces a recreate: existing groups keep their key, new ones get the CMK.
  lifecycle {
    ignore_changes = [kms_key_id]
  }
  transit_encryption_enabled = local.redis_tls
  transit_encryption_mode    = local.redis_tls_mode
  auth_token                 = local.redis_auth ? random_password.redis_auth["gateway"].result : null
  auth_token_update_strategy = local.redis_token_strategy
  apply_immediately          = true

  # TLS modifies can exceed the provider's 40m default.
  timeouts {
    update = "90m"
  }

  tags = {
    Name = "pavo-gw-redis-${var.instance_id}"
  }
}

resource "aws_elasticache_replication_group" "onboarding" {
  replication_group_id = "pavo-onboard-redis-${var.instance_id}"
  description          = "Pavo onboarding Redis (${var.instance_id})"

  node_type                  = var.redis_node_type
  num_cache_clusters         = 1
  engine_version             = "7.1"
  port                       = 6379
  parameter_group_name       = "default.redis7"
  automatic_failover_enabled = false

  subnet_group_name          = aws_elasticache_subnet_group.pavo.name
  security_group_ids         = [aws_security_group.elasticache.id]
  at_rest_encryption_enabled = true
  kms_key_id                 = data.aws_kms_key.cell_cmk.arn
  # Key change forces a recreate: existing groups keep their key, new ones get the CMK.
  lifecycle {
    ignore_changes = [kms_key_id]
  }
  transit_encryption_enabled = local.redis_tls
  transit_encryption_mode    = local.redis_tls_mode
  auth_token                 = local.redis_auth ? random_password.redis_auth["onboarding"].result : null
  auth_token_update_strategy = local.redis_token_strategy
  apply_immediately          = true

  # TLS modifies can exceed the provider's 40m default.
  timeouts {
    update = "90m"
  }

  tags = {
    Name = "pavo-onboard-redis-${var.instance_id}"
  }
}

resource "aws_elasticache_replication_group" "intern" {
  replication_group_id = "pavo-intern-redis-${var.instance_id}"
  description          = "Pavo intern Redis (${var.instance_id})"

  node_type                  = var.redis_node_type
  num_cache_clusters         = 1
  engine_version             = "7.1"
  port                       = 6379
  parameter_group_name       = "default.redis7"
  automatic_failover_enabled = false

  subnet_group_name          = aws_elasticache_subnet_group.pavo.name
  security_group_ids         = [aws_security_group.elasticache.id]
  at_rest_encryption_enabled = true
  kms_key_id                 = data.aws_kms_key.cell_cmk.arn
  # Key change forces a recreate: existing groups keep their key, new ones get the CMK.
  lifecycle {
    ignore_changes = [kms_key_id]
  }
  transit_encryption_enabled = local.redis_tls
  transit_encryption_mode    = local.redis_tls_mode
  auth_token                 = local.redis_auth ? random_password.redis_auth["intern"].result : null
  auth_token_update_strategy = local.redis_token_strategy
  apply_immediately          = true

  # TLS modifies can exceed the provider's 40m default.
  timeouts {
    update = "90m"
  }

  tags = {
    Name = "pavo-intern-redis-${var.instance_id}"
  }
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

  s3_buckets = {
    onboarding  = { name = "pavo-${var.customer_name}-onboard-${var.instance_id}" }
    intern_data = { name = "pavo-${var.customer_name}-data-${var.instance_id}" }
  }
}

resource "aws_s3_bucket" "pavo" {
  for_each      = local.s3_buckets
  bucket        = each.value.name
  force_destroy = var.force_destroy_buckets
  tags          = { Name = each.value.name }
}

resource "aws_s3_bucket_versioning" "pavo" {
  for_each = aws_s3_bucket.pavo
  bucket   = each.value.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "pavo" {
  for_each = aws_s3_bucket.pavo
  bucket   = each.value.id

  rule {
    id     = "retain-live-reap-archived-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days           = 1
      newer_noncurrent_versions = 10
    }
  }

  depends_on = [aws_s3_bucket_versioning.pavo]
}

# Cell CMK. Only new objects use it; existing ones keep SSE-S3 until rewritten.
resource "aws_s3_bucket_server_side_encryption_configuration" "pavo" {
  for_each = aws_s3_bucket.pavo
  bucket   = each.value.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = data.aws_kms_key.cell_cmk.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "pavo" {
  for_each                = aws_s3_bucket.pavo
  bucket                  = each.value.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# CORS is intern_data only (presigned URL access from the browser). Do not
# add it to onboarding — that would be a real AWS change, not a DRY rewrite.
resource "aws_s3_bucket_cors_configuration" "intern_data" {
  bucket = aws_s3_bucket.pavo["intern_data"].id

  cors_rule {
    allowed_headers = ["*"]
    allowed_methods = ["GET", "HEAD", "PUT", "POST", "DELETE"]
    allowed_origins = local.cors_origins
    expose_headers  = ["ETag", "Content-Length", "Content-Type"]
    max_age_seconds = 3600
  }
}

# Singleton -> for_each address remap. Without these, apply would destroy the
# live buckets and create empty ones with the same names.
moved {
  from = aws_s3_bucket.onboarding
  to   = aws_s3_bucket.pavo["onboarding"]
}
moved {
  from = aws_s3_bucket.intern_data
  to   = aws_s3_bucket.pavo["intern_data"]
}
moved {
  from = aws_s3_bucket_versioning.onboarding
  to   = aws_s3_bucket_versioning.pavo["onboarding"]
}
moved {
  from = aws_s3_bucket_versioning.intern_data
  to   = aws_s3_bucket_versioning.pavo["intern_data"]
}
moved {
  from = aws_s3_bucket_lifecycle_configuration.onboarding
  to   = aws_s3_bucket_lifecycle_configuration.pavo["onboarding"]
}
moved {
  from = aws_s3_bucket_lifecycle_configuration.intern_data
  to   = aws_s3_bucket_lifecycle_configuration.pavo["intern_data"]
}
moved {
  from = aws_s3_bucket_server_side_encryption_configuration.onboarding
  to   = aws_s3_bucket_server_side_encryption_configuration.pavo["onboarding"]
}
moved {
  from = aws_s3_bucket_server_side_encryption_configuration.intern_data
  to   = aws_s3_bucket_server_side_encryption_configuration.pavo["intern_data"]
}
moved {
  from = aws_s3_bucket_public_access_block.onboarding
  to   = aws_s3_bucket_public_access_block.pavo["onboarding"]
}
moved {
  from = aws_s3_bucket_public_access_block.intern_data
  to   = aws_s3_bucket_public_access_block.pavo["intern_data"]
}

# -----------------------------------------------------------------------------
# SNS Topics ×2 + SQS Queues ×3 main + ×3 DLQ
# -----------------------------------------------------------------------------
# Not three identical stacks: 2 topics, 3 queues, uneven wiring
# (orch → data_fetcher; nugget + rag → dedup). connector_sync below is a
# separate one-topic / N-queue for_each and is left alone.

locals {
  worker_topics = {
    data_fetcher = { name = "pavo-data-fetcher-topic-${var.instance_id}" }
    dedup        = { name = "pavo-dedup-topic-${var.instance_id}" }
  }
  worker_queues = {
    orch   = { topic = "data_fetcher" }
    nugget = { topic = "dedup" }
    rag    = { topic = "dedup" }
  }
}

resource "aws_sns_topic" "pavo" {
  for_each          = local.worker_topics
  name              = each.value.name
  kms_master_key_id = data.aws_kms_key.cell_cmk.arn
  # Existing topics keep their key so cells without the SNS boundary grant keep publishing.
  lifecycle {
    ignore_changes = [kms_master_key_id]
  }
  tags = { Name = each.value.name }
}

# SQS DLQs (must exist before main queues reference them)
# All queues use the cell CMK; SNS delivery needs the key policy statement
# AllowSNSToSQSUnderCellKey (scripts/create-cmk.sh).
resource "aws_sqs_queue" "worker_dlq" {
  for_each                  = local.worker_queues
  name                      = "pavo-${each.key}-dlq-${var.instance_id}"
  message_retention_seconds = 1209600 # 14 days
  kms_master_key_id         = data.aws_kms_key.cell_cmk.arn
  tags                      = { Name = "pavo-${each.key}-dlq-${var.instance_id}" }
}

# SQS main queues with redrive to DLQs. 7-day retention: these workers are KEDA
# scale-to-zero (minReplicas 0), so a wedged-at-0 weekend must not lose
# messages. Matches the GCP worker subs' 7-day default and the connector_sync
# queues. (DLQs already retain 14 days.)
resource "aws_sqs_queue" "worker" {
  for_each                   = local.worker_queues
  name                       = "pavo-${each.key}-sub-${var.instance_id}"
  visibility_timeout_seconds = 600
  message_retention_seconds  = 604800
  kms_master_key_id          = data.aws_kms_key.cell_cmk.arn

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.worker_dlq[each.key].arn
    maxReceiveCount     = 5
  })

  tags = { Name = "pavo-${each.key}-sub-${var.instance_id}" }
}

resource "aws_sns_topic_subscription" "worker" {
  for_each             = local.worker_queues
  topic_arn            = aws_sns_topic.pavo[each.value.topic].arn
  protocol             = "sqs"
  endpoint             = aws_sqs_queue.worker[each.key].arn
  raw_message_delivery = true
}

resource "aws_sqs_queue_policy" "worker" {
  for_each  = local.worker_queues
  queue_url = aws_sqs_queue.worker[each.key].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "sns.amazonaws.com" }
      Action    = "sqs:SendMessage"
      Resource  = aws_sqs_queue.worker[each.key].arn
      Condition = {
        ArnEquals = { "aws:SourceArn" = aws_sns_topic.pavo[each.value.topic].arn }
      }
    }]
  })
}

# Singleton -> for_each address remap. Without these, apply would destroy the
# live topics/queues (dropping in-flight messages) and create new ones.
moved {
  from = aws_sns_topic.data_fetcher
  to   = aws_sns_topic.pavo["data_fetcher"]
}
moved {
  from = aws_sns_topic.dedup
  to   = aws_sns_topic.pavo["dedup"]
}
moved {
  from = aws_sqs_queue.orch_dlq
  to   = aws_sqs_queue.worker_dlq["orch"]
}
moved {
  from = aws_sqs_queue.nugget_dlq
  to   = aws_sqs_queue.worker_dlq["nugget"]
}
moved {
  from = aws_sqs_queue.rag_dlq
  to   = aws_sqs_queue.worker_dlq["rag"]
}
moved {
  from = aws_sqs_queue.orch
  to   = aws_sqs_queue.worker["orch"]
}
moved {
  from = aws_sqs_queue.nugget
  to   = aws_sqs_queue.worker["nugget"]
}
moved {
  from = aws_sqs_queue.rag
  to   = aws_sqs_queue.worker["rag"]
}
moved {
  from = aws_sns_topic_subscription.orch
  to   = aws_sns_topic_subscription.worker["orch"]
}
moved {
  from = aws_sns_topic_subscription.nugget
  to   = aws_sns_topic_subscription.worker["nugget"]
}
moved {
  from = aws_sns_topic_subscription.rag
  to   = aws_sns_topic_subscription.worker["rag"]
}
moved {
  from = aws_sqs_queue_policy.orch
  to   = aws_sqs_queue_policy.worker["orch"]
}
moved {
  from = aws_sqs_queue_policy.nugget
  to   = aws_sqs_queue_policy.worker["nugget"]
}
moved {
  from = aws_sqs_queue_policy.rag
  to   = aws_sqs_queue_policy.worker["rag"]
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
  name              = "pavo-connector-sync-topic-${var.instance_id}"
  kms_master_key_id = data.aws_kms_key.cell_cmk.arn
  # Existing topics keep their key so cells without the SNS boundary grant keep publishing.
  lifecycle {
    ignore_changes = [kms_master_key_id]
  }
  tags = { Name = "pavo-connector-sync-topic-${var.instance_id}" }
}

# Shared DLQ for all connector queues.
resource "aws_sqs_queue" "connector_sync_dlq" {
  name                      = "pavo-connector-sync-dlq-${var.instance_id}"
  message_retention_seconds = 1209600 # 14 days
  kms_master_key_id         = data.aws_kms_key.cell_cmk.arn
  tags                      = { Name = "pavo-connector-sync-dlq-${var.instance_id}" }
}

# One queue per connector type, with redrive to the shared DLQ.
resource "aws_sqs_queue" "connector_sync" {
  for_each                   = toset(local.connector_types)
  name                       = "pavo-connector-sync-${each.key}-sub-${var.instance_id}"
  visibility_timeout_seconds = 600
  message_retention_seconds  = 604800 # 7 days — parity with GCP connector subs; preserves the scale-to-zero backlog buffer (KEDA wedged at 0 over a weekend must not lose messages)
  kms_master_key_id          = data.aws_kms_key.cell_cmk.arn

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
      [for q in aws_sqs_queue.worker : q.arn],
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
# lives in the KEDA cell amenity, created by the keda
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
# e.g. a cell that ran the old path): the live CTA was created by terraform's field-manager with no Helm
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
  encrypted  = true
  kms_key_id = data.aws_kms_key.cell_cmk.arn

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
    # why adding an inline policy during an earlier customer onboarding changed
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

  # Key change forces a recreate (data loss): existing filesystems keep their key, new ones get the CMK.
  lifecycle {
    ignore_changes = [kms_key_id]
  }
}

resource "aws_efs_mount_target" "pavo" {
  for_each = toset(data.aws_subnets.private.ids)

  file_system_id  = aws_efs_file_system.pavo.id
  subnet_id       = each.value
  security_groups = [aws_security_group.efs.id]
}

# Omnistrate-owned IRSA role the CSI node mounts with (name carries a per-cluster hash).
# If Omnistrate recreates the role, the policy below still names the old role's
# unique ID and mounts are denied until the next apply of this module.
data "kubernetes_service_account_v1" "efs_csi_node" {
  count = var.efs_iam_auth_enforced ? 1 : 0

  metadata {
    name      = "efs-csi-node-sa"
    namespace = "kube-system"
  }

  lifecycle {
    postcondition {
      condition     = try(self.metadata[0].annotations["eks.amazonaws.com/role-arn"], "") != ""
      error_message = "kube-system/efs-csi-node-sa has no eks.amazonaws.com/role-arn annotation; EFS file system policy cannot name the CSI role."
    }
  }
}

# Mount only over TLS and only through an access point (so the StorageClass
# uid/gid/directoryPerms always apply). No ClientRootAccess.
# efs_iam_auth_enforced: only the CSI role may mount; otherwise any client
# (anonymous, as existing PVs mount) passing the SG.
data "aws_iam_policy_document" "efs" {
  statement {
    sid       = "ClientMount"
    effect    = "Allow"
    actions   = ["elasticfilesystem:ClientMount", "elasticfilesystem:ClientWrite"]
    resources = [aws_efs_file_system.pavo.arn]

    principals {
      type        = "AWS"
      identifiers = var.efs_iam_auth_enforced ? [data.kubernetes_service_account_v1.efs_csi_node[0].metadata[0].annotations["eks.amazonaws.com/role-arn"]] : ["*"]
    }
  }

  statement {
    sid       = "DenyNonTls"
    effect    = "Deny"
    actions   = ["*"]
    resources = [aws_efs_file_system.pavo.arn]

    principals {
      type        = "AWS"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }

  # Safe while the CSI controller runs with --delete-access-point-root-dir=false
  # (Omnistrate default); that flag mounts the filesystem root.
  statement {
    sid       = "DenyMountWithoutAccessPoint"
    effect    = "Deny"
    actions   = ["elasticfilesystem:ClientMount"]
    resources = [aws_efs_file_system.pavo.arn]

    principals {
      type        = "AWS"
      identifiers = ["*"]
    }

    condition {
      test     = "Null"
      variable = "elasticfilesystem:AccessPointArn"
      values   = ["true"]
    }
  }
}

resource "aws_efs_file_system_policy" "pavo" {
  file_system_id = aws_efs_file_system.pavo.id
  policy         = data.aws_iam_policy_document.efs.json
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
    resources = flatten([
      for b in aws_s3_bucket.pavo : [b.arn, "${b.arn}/*"]
    ])
  }

  # SNS publish
  statement {
    effect  = "Allow"
    actions = ["sns:Publish"]
    resources = concat(
      [for t in aws_sns_topic.pavo : t.arn],
      # connector_sync: the orchestrator dispatcher publishes connector jobs here
      # (attribute-routed to the per-type queues). Without this, dispatch fails AccessDenied.
      [aws_sns_topic.connector_sync.arn],
    )
  }

  # SNS publish, S3 objects and SQS receive under the cell key.
  statement {
    effect    = "Allow"
    actions   = ["kms:GenerateDataKey", "kms:Decrypt"]
    resources = [data.aws_kms_key.cell_cmk.arn]
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["sns.${var.aws_region}.amazonaws.com", "s3.${var.aws_region}.amazonaws.com", "sqs.${var.aws_region}.amazonaws.com"]
    }
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
      [for q in aws_sqs_queue.worker : q.arn],
      [for q in aws_sqs_queue.worker_dlq : q.arn],
      [aws_sqs_queue.connector_sync_dlq.arn],
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
      # Opus 5 (2026-10-02): the Multi-Tenant plan's book writer moves to it
      # (spec bookAgentModel delta in render-multitenant-spec.py). Listed for
      # both plans so a BYOC cell can follow with a spec change alone.
      "arn:aws:bedrock:*::foundation-model/anthropic.claude-opus-5",
      "arn:aws:bedrock:${var.aws_region}:${data.aws_caller_identity.current.account_id}:inference-profile/us.anthropic.claude-opus-5",
      # Opus 5.5 (2026-10-07): the Multi-Tenant plan's book writer moves to it
      # once the tribal image that speaks its request contract is live (forced
      # tool choice 400s, thinking cannot be disabled). Listed for both plans
      # so a BYOC cell can follow with a spec change alone.
      "arn:aws:bedrock:*::foundation-model/anthropic.claude-opus-5-5",
      "arn:aws:bedrock:${var.aws_region}:${data.aws_caller_identity.current.account_id}:inference-profile/us.anthropic.claude-opus-5-5",
      "arn:aws:bedrock:*::foundation-model/amazon.titan-embed-text-v2:0",
    ]
  }

  # NOTE: there is deliberately NO `elasticache:Connect` and NO `rds-db:connect`
  # statement here. ElastiCache IAM authentication requires
  # transit encryption AND an ElastiCache user with AuthenticationMode `iam`.
  # These replication groups authenticate with an AUTH token (default user, no
  # user groups), so no client ever signs an `elasticache:Connect` request. The
  # grant existed from the module's first commit alongside
  # `transit_encryption_enabled = false`, so it was never functional.
  # RDS IAM authentication is the same class of dead grant:
  # `iam_database_authentication_enabled` is not set, and the apps use the
  # Secrets Manager password. Re-add either grant (and any matching boundary
  # statement in pavo-bootstrap-aws/policy-statements.json) only when the
  # corresponding mechanism is actually switched on. For ElastiCache, ALL THREE
  # must hold:
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

  # Lambda MicroVMs computer backend — the sandbox/exec runtime can run on AWS
  # Lambda MicroVMs instead of E2B. The lifecycle + image-read calls go through
  # the "lambda:" IAM namespace (the service's signingName is "lambda", NOT
  # "lambda-microvms"), so without these grants every RunMicrovm/GetMicrovm call
  # is AccessDenied even though nothing else about the role changes. Scoped to
  # this account's microvm and microvm-image ARNs. NO image-write actions
  # (CreateMicrovmImage etc.) — image builds stay in the vendor account.
  #
  # UNCONDITIONAL — and it has to stay that way. These statements were gated on
  # var.enable_lambda_microvms, a per-instance Omnistrate parameter. Every
  # instance deploy runs an early Terraform phase in which that parameter is
  # absent, so the gate rendered false, this policy was re-applied WITHOUT the
  # MicroVM statements, and a later phase put them back. Each deploy therefore
  # opened a window in which every sandbox on the cell failed AccessDenied on
  # RunMicrovm — 2026-08-17 09:48Z→11:07Z and 2026-08-18 12:36Z→13:04Z in the
  # role's CloudTrail PutRolePolicy history. Any gate sourced from a per-instance
  # value reintroduces that outage; do not add one back.
  #
  # The account-level control is the permission boundary attached to
  # aws_iam_role.pavo below, whose content comes from
  # pavo-bootstrap-aws/policy-statements.json: in an account whose boundary omits
  # the MicroVM ceiling these grants cap to nothing (implicit deny, not an
  # error). Verify against a live role with scripts/verify-microvm-grants.py.
  statement {
    effect = "Allow"
    actions = [
      "lambda:RunMicrovm",
      "lambda:GetMicrovm",
      "lambda:ListMicrovms",
      "lambda:SuspendMicrovm",
      "lambda:ResumeMicrovm",
      "lambda:TerminateMicrovm",
      "lambda:CreateMicrovmAuthToken",
      # Read-only microvm-image lookups.
      "lambda:GetMicrovmImage",
      "lambda:ListMicrovmImages",
      "lambda:ListMicrovmImageVersions",
    ]
    resources = [
      "arn:aws:lambda:${var.aws_region}:${data.aws_caller_identity.current.account_id}:microvm*",
      "arn:aws:lambda:${var.aws_region}:${data.aws_caller_identity.current.account_id}:microvm-image*",
    ]
  }

  # RunMicrovm implicitly attaches the INTERNET_EGRESS network connector and the
  # authorizer checks lambda:PassNetworkConnector against it — but it rejects
  # EVERY resource-scoped form of that ARN (the implicit connector exposes no
  # stable account-scoped ARN to name), so this MUST be Resource "*". Without it
  # RunMicrovm fails AccessDenied on PassNetworkConnector even when the lifecycle
  # grants above are correct. Unconditional for the same reason as above.
  statement {
    effect    = "Allow"
    actions   = ["lambda:PassNetworkConnector"]
    resources = ["*"]
  }

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

  # Connector IAM-role mode (Amazon SageMaker today): onboarding (connect and
  # Re-check), Tribal and intern all run as this role, and each assumes the
  # customer's role directly from it. Exactly the role ARNs the customer listed
  # in pavo-bootstrap-aws connector_assumable_role_arns (read from the cell in
  # cell_gates.tf, never from an instance parameter), and only with a Pavo-issued
  # external ID. This is the grant. The permission boundary carries only the
  # ceiling (ConnectorAssumeCustomerRoles in pavo-bootstrap-aws's
  # policy-statements.json: any role, Pavo external ID only), so the exact role
  # limit is this statement's. No cell value, no statement.
  dynamic "statement" {
    for_each = length(local.connector_assumable_role_arns) > 0 ? [1] : []
    content {
      sid       = "ConnectorAssumeCustomerRoles"
      effect    = "Allow"
      actions   = ["sts:AssumeRole"]
      resources = local.connector_assumable_role_arns
      condition {
        test     = "StringLike"
        variable = "sts:ExternalId"
        values   = ["pavo-*"]
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
        "anthropic.claude-opus-4-6-v1" \
        "anthropic.claude-opus-5" \
        "anthropic.claude-opus-5-5"; do

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
# ExternalSecrets — per-instance SecretStore + ExternalSecret
# -----------------------------------------------------------------------------
# The ESO controller + CRDs are cell-scoped (pavo-bootstrap-aws). Each instance
# brings its own identity: the `pavo-eso` ServiceAccount in the instance
# namespace assumes an IRSA role that reads only this instance's RDS master
# secret(s), and a namespaced SecretStore uses it, so no other namespace can
# reach these secrets through ESO. The temporal secret grant lives in
# temporal_self_hosted.tf.
locals {
  eso_service_account = "pavo-eso"
}

data "aws_iam_policy_document" "eso_trust" {
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
      values   = ["system:serviceaccount:${var.instance_id}:${local.eso_service_account}"]
    }

    condition {
      test     = "StringEquals"
      variable = "${var.eks_oidc_provider}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "eso" {
  name                 = "pavo-eso-${var.instance_id}"
  assume_role_policy   = data.aws_iam_policy_document.eso_trust.json
  permissions_boundary = data.aws_ssm_parameter.permission_boundary_arn.value

  tags = { Name = "pavo-eso-${var.instance_id}" }
}

data "aws_iam_policy_document" "eso" {
  statement {
    sid       = "ReadInstanceRDSSecret"
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    resources = [aws_db_instance.postgres.master_user_secret[0].secret_arn]
  }

  # The secret is encrypted with the cell CMK; Secrets Manager decrypts on the
  # caller's behalf.
  statement {
    sid       = "DecryptViaSecretsManager"
    effect    = "Allow"
    actions   = ["kms:Decrypt"]
    resources = [data.aws_kms_key.cell_cmk.arn]
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["secretsmanager.${var.aws_region}.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "eso" {
  name   = "pavo-eso-read"
  role   = aws_iam_role.eso.id
  policy = data.aws_iam_policy_document.eso.json
}

resource "kubernetes_service_account_v1" "eso" {
  metadata {
    name      = local.eso_service_account
    namespace = var.instance_id
    annotations = {
      "eks.amazonaws.com/role-arn" = aws_iam_role.eso.arn
    }
  }

  depends_on = [kubectl_manifest.instance_namespace]
}

# Was the per-instance ClusterSecretStore. moved turns the kind swap into a
# replace, so the ExternalSecrets' replace_triggered_by on `kind` fires.
moved {
  from = kubectl_manifest.eso_cluster_secret_store
  to   = kubectl_manifest.eso_secret_store
}

# Ready=True means ESO assumed the role, so the ExternalSecrets that depend on
# this store are not created before IRSA works.
resource "kubectl_manifest" "eso_secret_store" {
  yaml_body         = <<-YAML
    apiVersion: external-secrets.io/v1beta1
    kind: SecretStore
    metadata:
      name: pavo-aws-sm
      namespace: ${var.instance_id}
    spec:
      provider:
        aws:
          service: SecretsManager
          region: ${var.aws_region}
          auth:
            jwt:
              serviceAccountRef:
                name: ${kubernetes_service_account_v1.eso.metadata[0].name}
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

  depends_on = [
    aws_iam_role_policy.eso,
    kubectl_manifest.instance_namespace,
  ]
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
# (the wedge that hit a live instance). Intentional manifest updates require:
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
        name: pavo-aws-sm
        kind: SecretStore
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
    # and the store kind swap, because yaml_body embeds them. replace_triggered_by
    # re-creates this manifest when either changes. The replace deletes the
    # owned K8s Secret until ESO re-syncs it (same values), so pods starting in
    # that window wait on CreateContainerConfigError; running pods are unaffected.
    replace_triggered_by = [aws_db_instance.postgres, kubectl_manifest.eso_secret_store.kind]
  }

  depends_on = [
    kubectl_manifest.eso_secret_store,
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

  # `iam` signs the mount with the CSI role so aws_efs_file_system_policy.pavo admits it.
  # ForceNew; already-bound PVs keep the options they were provisioned with.
  mount_options = var.efs_iam_auth_enforced ? ["tls", "iam"] : null

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
  count = local.effective_es_mode == "cloud" ? 1 : 0

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
# (e.g. a live cloud instance) mapped to [0] so they are NOT destroyed/recreated on apply.
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
  count = local.effective_es_mode == "cloud" && var.elasticsearch_api_key == "" ? 1 : 0

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
# providers.tf. Pre-#118 instances (created
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
# first successful plan that processes the `removed` block). After existing
# instances reach RUNNING on this version, drop these in a
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
# against this code. Safe to drop in a cleanup PR after existing instances
# re-reach RUNNING on this version.
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
