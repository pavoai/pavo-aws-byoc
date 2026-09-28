# =============================================================================
# Self-hosted Temporal — per-instance (in-VPC workflow orchestration)
# =============================================================================
# Materializes ONLY when temporal_mode = "self_hosted". Default temporal_mode =
# "cloud" (Temporal Cloud gdv7k) is completely unchanged — every resource here
# is count/for_each-gated, so this file is purely additive and touches nothing
# on the existing cloud path.
#
# Layout (LLD: Self-hosting Temporal, vchandela):
#   1. Dedicated RDS PG16 (db.t4g.medium, Multi-AZ, gp3, customer CMK, 7d PITR)
#      with `temporal` + `temporal_visibility` DBs — SQL visibility, no ES.
#   2. ESO secrets: RDS master creds sync + generated passwords for the two DB
#      roles (temporal_schema_admin = DDL/Jobs-only, temporal_runtime = DML) +
#      Web UI basic-auth credential. Nothing generated enters TF state.
#   3. cert-manager PKI: SelfSigned Issuer → root CA (10y) → CA Issuer → leaf
#      certs (90d, renewBefore 30d): frontend server cert (SAN-pinned to
#      temporal-frontend.<ns>.svc — clients need NO server-name override) and
#      client certs for intern, Web UI, admin Jobs, and the system worker.
#   4. Terraform-ordered Jobs (wait_for_completion is the ordering mechanism):
#      DB bootstrap (psql, master cred, ALTER ROLE reconcile, \gexec) →
#      schema setup (temporal-sql-tool as temporal_schema_admin) →
#      helm release → namespace registration (temporal CLI over mTLS; its
#      successful connect doubles as the frontend SAN/mTLS acceptance check).
#   5. temporalio/helm-charts 1.6.0: server-only (web/admintools/chart-schema
#      disabled — the chart still emits a no-op "schema" Job, known & harmless),
#      frontend mTLS + systemWorker TLS, stock size limits (2MB blob / 4MB gRPC,
#      Temporal Cloud parity — evidence: no blob-size errors in prod logs).
#   6. temporal-web: UI + optional payload-codec sidecar bound to 127.0.0.1;
#      the ONLY exposed port is an nginx sidecar enforcing basic auth on `/`
#      AND the same-origin `/codec` proxy (browser-originated decode calls).
#      Ingress rides pavo-nginx like Kibana/Zitadel, so exposure (and the
#      issuer: public ACME vs private CA) follows the cell's network_posture.
#
# Images are ghcr.io/pavoai/mirror/* digest pins (Docker Hub anonymous pulls
# share the cell NAT and rate-limit; precedent: postgres via public.ecr.aws,
# zitadel via ghcr). Copy with scripts/mirror-temporal-images.sh — digests are
# preserved by the copy, so the pins below equal the upstream Docker Hub
# digests.

locals {
  temporal_self_hosted = var.temporal_mode == "self_hosted"
  temporal_count       = local.temporal_self_hosted ? 1 : 0

  temporal_namespace_k8s = var.instance_id
  # Temporal (logical) namespace — matches the Cloud naming minus the .gdv7k
  # suffix so dashboards/runbooks stay recognizable.
  temporal_namespace = "pavo-${var.customer_name}-intern"
  # 30d retention — Cloud parity.
  temporal_namespace_retention = "720h"

  # helm fullnameOverride "temporal" → services temporal-frontend/-history/....
  # The frontend cert SANs pin this name; keep the three forms in sync.
  temporal_frontend_service = "temporal-frontend"
  temporal_frontend_host    = "temporal-frontend.${var.instance_id}.svc"
  temporal_frontend_port    = 7233

  temporal_web_host = "temporal.${var.customer_name}.${var.base_domain}"

  # Codec sidecar (Web UI payload decode) only when the customer key is set AND
  # an intern codec image was pinned. Off = UI shows encoded payloads (codec is
  # defense-in-depth, not a residency requirement).
  temporal_codec_enabled = (
    local.temporal_self_hosted &&
    trimspace(var.temporal_payload_codec_key) != "" &&
    trimspace(var.temporal_codec_image) != ""
  )

  # --- images (digest pins == upstream Docker Hub digests, copy-preserved) ---
  # temporalio/server 1.31.2 (chart 1.6.0 appVersion)
  temporal_server_image_repo = "ghcr.io/pavoai/mirror/temporalio/server"
  temporal_server_image_tag  = "1.31.2@sha256:b5ecdb8282bededae2a10c36e8d862e27d0bc2d247fc73c5416025997ab4a1da"
  # temporalio/admin-tools 1.31.2 — temporal-sql-tool + temporal CLI (Jobs)
  temporal_admin_tools_image_repo = "ghcr.io/pavoai/mirror/temporalio/admin-tools"
  temporal_admin_tools_image_tag  = "1.31.2@sha256:dbc5fcd6ee8f0f4d808bf765af9a87dea9d8a283abfdcfbd2fc148496ba66107"
  temporal_admin_tools_image      = "${local.temporal_admin_tools_image_repo}:${local.temporal_admin_tools_image_tag}"
  # temporalio/ui 2.53.0
  temporal_ui_image = "ghcr.io/pavoai/mirror/temporalio/ui:2.53.0@sha256:810eba47f77a89b0e64e2e751478ca585d037bbd90c0951a2974a92a6c5adeb9"
  # nginx auth sidecar — public.ecr.aws (unlimited anonymous, postgres precedent)
  temporal_nginx_image = "public.ecr.aws/nginx/nginx:1.29-alpine@sha256:72c9b856fee09b02f9e5ee29ab2b55ae9a3c3b59cf094baef1d05f5914d8cb17"

  # Same amd64 workload-nodegroup pin as the zitadel stack: keeps Temporal off
  # the small arm64 system nodes, and the (amd64-only) intern codec image needs
  # it anyway.
  temporal_node_selector = {
    "node.kubernetes.io/instance-type" = "t3.2xlarge"
  }

  # --- canonical in-cluster object names (single source of truth) -------------
  temporal_rds_master_secret    = "temporal-rds-master-credentials"
  temporal_runtime_db_secret    = "temporal-db-runtime"
  temporal_schema_db_secret     = "temporal-db-schema-admin"
  temporal_ui_auth_secret       = "temporal-ui-auth"
  temporal_codec_key_secret     = "temporal-codec-key"
  temporal_root_ca_secret       = "temporal-root-ca"
  temporal_frontend_cert_secret = "temporal-frontend-cert"
  temporal_intern_cert_secret   = "temporal-intern-client-cert" # also exported via outputs.tf

  # DB roles: generator name + ESO target secret per role.
  temporal_db_roles = local.temporal_self_hosted ? {
    (local.temporal_runtime_db_secret) = { generator = "temporal-runtime-pw", username = "temporal_runtime" }
    (local.temporal_schema_db_secret)  = { generator = "temporal-schema-admin-pw", username = "temporal_schema_admin" }
  } : {}

  # Client leaf certs (mTLS to the frontend). Secret name → CN. The frontend
  # server cert is separate (server usages + DNS SANs).
  temporal_client_certs = local.temporal_self_hosted ? {
    (local.temporal_intern_cert_secret) = "pavo-intern"        # intern app + workers
    "temporal-ui-client-cert"           = "temporal-web-ui"    # Web UI → frontend
    "temporal-admin-client-cert"        = "temporal-admin-job" # namespace/ops Jobs
    "temporal-worker-client-cert"       = "temporal-system-worker"
  } : {}

  temporal_web_labels = {
    "app.kubernetes.io/name"     = "temporal-web"
    "app.kubernetes.io/instance" = var.instance_id
  }

  # Per-role HA (chart 1.6.0 per-service keys): PDB minAvailable 1 + spread.
  # Hostname spread is hard (needs only 2 nodes); zone spread is soft — the
  # t3.2xlarge nodegroup is not proven multi-AZ, and an unsatisfiable hard
  # constraint would leave pods Pending and fail the apply at helm wait.
  # labelSelector must be component-scoped — a broad selector would let one
  # role's placement satisfy another's constraint. Labels match the chart's
  # pod labels (name = chart name, instance = release name, both "temporal").
  temporal_server_role_ha = {
    for role in ["frontend", "history", "matching", "worker"] : role => {
      podDisruptionBudget = { minAvailable = 1 }
      topologySpreadConstraints = [
        for tk, unsat in {
          "topology.kubernetes.io/zone" = "ScheduleAnyway"
          "kubernetes.io/hostname"      = "DoNotSchedule"
          } : {
          maxSkew           = 1
          topologyKey       = tk
          whenUnsatisfiable = unsat
          labelSelector = {
            matchLabels = {
              "app.kubernetes.io/name"      = "temporal"
              "app.kubernetes.io/instance"  = "temporal"
              "app.kubernetes.io/component" = role
            }
          }
        }
      ]
    }
  }
}

# --- Fail-fast: self-hosted Temporal must be monitorable in-VPC ---------------
resource "terraform_data" "temporal_mode_guard" {
  count = local.temporal_count

  lifecycle {
    precondition {
      condition     = var.grafana_mode == "self_hosted"
      error_message = "temporal_mode=self_hosted requires grafana_mode=self_hosted: the in-VPC Prometheus is what scrapes the Temporal server; without it the cluster runs blind (and Grafana Cloud egress would defeat the residency goal)."
    }
  }
}

# -----------------------------------------------------------------------------
# 1. Dedicated RDS — Temporal is the source of truth for workflow state, so it
#    gets its own instance (blast-radius + connection isolation from the shared
#    app RDS). Same subnet group / SG / CMK / snapshot conventions as
#    aws_db_instance.postgres.
# -----------------------------------------------------------------------------
resource "aws_db_instance" "temporal" {
  count = local.temporal_count

  identifier            = "pavo-temporal-${var.instance_id}"
  engine                = "postgres"
  engine_version        = var.postgres_engine_version
  instance_class        = "db.t4g.medium"
  allocated_storage     = 50
  max_allocated_storage = 200
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
  final_snapshot_identifier = var.create_final_snapshot ? "pavo-temporal-final-${var.instance_id}" : null

  backup_retention_period = 7
  backup_window           = "03:00-04:00"
  maintenance_window      = "sun:04:00-sun:05:00"

  tags = {
    Name = "pavo-temporal-${var.instance_id}"
  }

  depends_on = [terraform_data.temporal_mode_guard]
}

# aws_db_instance already blocks until status "available", but "available" is
# not "accepting connections" — DNS for the endpoint can lag and the engine
# can still be warming. Same 120s buffer as main.tf's wait_for_rds (proven on
# the shared RDS + create_databases path); the bootstrap Job's backoff is the
# second line of defense, this keeps first-apply logs clean of retry noise.
resource "time_sleep" "wait_for_temporal_rds" {
  count           = local.temporal_count
  depends_on      = [aws_db_instance.temporal]
  create_duration = "120s"
}

# Master creds → K8s Secret (bootstrap Job only; runtime never sees them).
# Same alekc/kubectl SSA-drift guard as external_secret_db_credentials.
resource "kubectl_manifest" "temporal_rds_master_external_secret" {
  count = local.temporal_count

  yaml_body = yamlencode({
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ExternalSecret"
    metadata = {
      name      = local.temporal_rds_master_secret
      namespace = local.temporal_namespace_k8s
    }
    spec = {
      refreshInterval = "5m"
      secretStoreRef = {
        name = "pavo-aws-sm-${var.instance_id}"
        kind = "ClusterSecretStore"
      }
      target = {
        name           = local.temporal_rds_master_secret
        creationPolicy = "Owner"
      }
      data = [
        {
          secretKey = "username"
          remoteRef = {
            key      = aws_db_instance.temporal[0].master_user_secret[0].secret_arn
            property = "username"
          }
        },
        {
          secretKey = "password"
          remoteRef = {
            key      = aws_db_instance.temporal[0].master_user_secret[0].secret_arn
            property = "password"
          }
        },
      ]
    }
  })

  server_side_apply = true
  force_conflicts   = true
  wait_for {
    field {
      key        = "status.conditions.[0].status"
      value      = "True"
      value_type = "eq"
    }
  }
  timeouts {
    create = "5m"
  }
  lifecycle {
    ignore_changes       = [yaml_body]
    replace_triggered_by = [aws_db_instance.temporal[0]]
  }
  depends_on = [
    kubectl_manifest.eso_cluster_secret_store,
    kubectl_manifest.instance_namespace,
  ]
}

# RDS CA trust anchor — the pinned AWS global bundle embedded as a .tf literal
# (see temporal_rds_ca_bundle.tf for why it can be neither a repo data file nor
# a plan-time fetch). Every SQL client (bootstrap psql, temporal-sql-tool,
# server datastores) mounts this and verifies the RDS hostname — TLS without
# host verification would still accept a MITM with any RDS-signed cert.
resource "kubernetes_config_map_v1" "temporal_rds_ca" {
  count = local.temporal_count

  metadata {
    name      = "temporal-rds-ca"
    namespace = local.temporal_namespace_k8s
  }

  data = {
    "rds-ca.pem" = local.rds_global_ca_bundle
  }

  depends_on = [kubectl_manifest.instance_namespace]
}

# -----------------------------------------------------------------------------
# 2. DB-role passwords — ESO generate-once (never in TF state), zitadel pattern:
#    refreshInterval "0", symbols 0 (no psql-quoting hazards), ignore_changes.
# -----------------------------------------------------------------------------
resource "kubectl_manifest" "temporal_db_password_generator" {
  for_each = local.temporal_db_roles

  yaml_body = yamlencode({
    apiVersion = "generators.external-secrets.io/v1alpha1"
    kind       = "Password"
    metadata = {
      name      = each.value.generator
      namespace = local.temporal_namespace_k8s
    }
    spec = {
      length      = 32
      digits      = 6
      symbols     = 0
      noUpper     = false
      allowRepeat = true
    }
  })

  server_side_apply = true
  force_conflicts   = true
  lifecycle {
    ignore_changes = [yaml_body]
  }
  depends_on = [kubectl_manifest.instance_namespace]
}

# Role creds → Secrets. Key "password" doubles as the helm chart's
# existingSecret contract (default secretKey: password).
resource "kubectl_manifest" "temporal_db_role_external_secret" {
  for_each = local.temporal_db_roles

  yaml_body = yamlencode({
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ExternalSecret"
    metadata = {
      name      = each.key
      namespace = local.temporal_namespace_k8s
    }
    spec = {
      refreshInterval = "0"
      target = {
        name           = each.key
        creationPolicy = "Owner"
        template = {
          engineVersion = "v2"
          data = {
            username = each.value.username
            password = "{{ .password }}"
          }
        }
      }
      dataFrom = [{
        sourceRef = {
          generatorRef = {
            apiVersion = "generators.external-secrets.io/v1alpha1"
            kind       = "Password"
            name       = each.value.generator
          }
        }
      }]
    }
  })

  server_side_apply = true
  force_conflicts   = true
  wait_for {
    field {
      key        = "status.conditions.[0].status"
      value      = "True"
      value_type = "eq"
    }
  }
  lifecycle {
    ignore_changes = [yaml_body]
  }
  depends_on = [
    kubectl_manifest.instance_namespace,
    kubectl_manifest.temporal_db_password_generator,
  ]
}

# Web UI basic-auth credential. ESO renders the nginx user file directly
# ({PLAIN} is a format nginx supports natively), so no htpasswd tooling is
# needed anywhere; operators read the `password` key to log in.
resource "kubectl_manifest" "temporal_ui_password_generator" {
  count = local.temporal_count

  yaml_body = yamlencode({
    apiVersion = "generators.external-secrets.io/v1alpha1"
    kind       = "Password"
    metadata = {
      name      = "temporal-ui-pw"
      namespace = local.temporal_namespace_k8s
    }
    spec = {
      length      = 32
      digits      = 6
      symbols     = 0
      noUpper     = false
      allowRepeat = true
    }
  })

  server_side_apply = true
  force_conflicts   = true
  lifecycle {
    ignore_changes = [yaml_body]
  }
  depends_on = [kubectl_manifest.instance_namespace]
}

resource "kubectl_manifest" "temporal_ui_auth_external_secret" {
  count = local.temporal_count

  yaml_body = yamlencode({
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ExternalSecret"
    metadata = {
      name      = local.temporal_ui_auth_secret
      namespace = local.temporal_namespace_k8s
    }
    spec = {
      refreshInterval = "0"
      target = {
        name           = local.temporal_ui_auth_secret
        creationPolicy = "Owner"
        template = {
          engineVersion = "v2"
          data = {
            username = "pavo"
            password = "{{ .password }}"
            htpasswd = "pavo:{PLAIN}{{ .password }}"
          }
        }
      }
      dataFrom = [{
        sourceRef = {
          generatorRef = {
            apiVersion = "generators.external-secrets.io/v1alpha1"
            kind       = "Password"
            name       = "temporal-ui-pw"
          }
        }
      }]
    }
  })

  server_side_apply = true
  force_conflicts   = true
  wait_for {
    field {
      key        = "status.conditions.[0].status"
      value      = "True"
      value_type = "eq"
    }
  }
  lifecycle {
    ignore_changes = [yaml_body]
  }
  depends_on = [
    kubectl_manifest.instance_namespace,
    kubectl_manifest.temporal_ui_password_generator,
  ]
}

# Codec key for the Web UI decode sidecar — the SAME customer key intern uses
# ($var.temporal_payload_codec_key feeds both this Secret and intern's chart
# values). ONE key per cell; do not generate a separate one.
#
# ACCEPTED: the raw key persists in this module's TF state (Omnistrate state,
# encrypted at rest). ESO cannot sync it — the key exists only as an
# Omnistrate $secret/apiParameter, never in AWS Secrets Manager, so there is
# no remote to reference. Rotation is therefore a state-touching op: modify
# the instance's temporal_payload_codec_key and re-apply (old payloads stay
# decodable only while the old key-id is honored — v0 static-key caveat).
resource "kubernetes_secret_v1" "temporal_codec_key" {
  # Same gate as its only consumer (the codec sidecar) — no orphan Secret
  # when the key is set but no codec image is pinned.
  count = local.temporal_codec_enabled ? 1 : 0

  metadata {
    name      = local.temporal_codec_key_secret
    namespace = local.temporal_namespace_k8s
  }

  data = {
    TEMPORAL_PAYLOAD_CODEC_KEY = trimspace(var.temporal_payload_codec_key)
  }

  depends_on = [kubectl_manifest.instance_namespace]
}

# -----------------------------------------------------------------------------
# 3. PKI — cert-manager: SelfSigned Issuer → root CA → CA Issuer → 5 leafs.
#    Keys never enter TF state; cert-manager auto-renews leafs (90d/renew 30d)
#    and the server hot-reloads them (tls.refreshInterval below).
# -----------------------------------------------------------------------------
resource "kubectl_manifest" "temporal_selfsigned_issuer" {
  count = local.temporal_count

  yaml_body = yamlencode({
    apiVersion = "cert-manager.io/v1"
    kind       = "Issuer"
    metadata = {
      name      = "temporal-selfsigned"
      namespace = local.temporal_namespace_k8s
    }
    spec = { selfSigned = {} }
  })

  server_side_apply = true
  force_conflicts   = true
  depends_on        = [kubectl_manifest.instance_namespace]
}

resource "kubectl_manifest" "temporal_root_ca" {
  count = local.temporal_count

  yaml_body = yamlencode({
    apiVersion = "cert-manager.io/v1"
    kind       = "Certificate"
    metadata = {
      name      = "temporal-root-ca"
      namespace = local.temporal_namespace_k8s
    }
    spec = {
      isCA        = true
      commonName  = "pavo-temporal-root-ca-${var.instance_id}"
      secretName  = local.temporal_root_ca_secret
      duration    = "87600h" # 10y — rotating the root is a full-cluster cert swap
      renewBefore = "8760h"  # 1y
      privateKey  = { algorithm = "ECDSA", size = 256 }
      issuerRef = {
        name  = "temporal-selfsigned"
        kind  = "Issuer"
        group = "cert-manager.io"
      }
    }
  })

  server_side_apply = true
  force_conflicts   = true
  # Match Ready by condition TYPE, not by array position. During issuance a
  # Certificate carries BOTH Ready and Issuing, and nothing guarantees their order
  # within status.conditions, so indexing [0] can read Issuing=True and return
  # while the cert is still being issued — before the Secret exists. Upstream on
  # the Issuing condition: "It will be removed by the 'issuing' controller upon
  # completing issuance." (cert-manager pkg/apis/certmanager/v1/types_certificate.go)
  wait_for {
    condition {
      type   = "Ready"
      status = "True"
    }
  }
  depends_on = [kubectl_manifest.temporal_selfsigned_issuer]
}

resource "kubectl_manifest" "temporal_ca_issuer" {
  count = local.temporal_count

  yaml_body = yamlencode({
    apiVersion = "cert-manager.io/v1"
    kind       = "Issuer"
    metadata = {
      name      = "temporal-ca"
      namespace = local.temporal_namespace_k8s
    }
    spec = {
      ca = { secretName = local.temporal_root_ca_secret }
    }
  })

  server_side_apply = true
  force_conflicts   = true
  depends_on        = [kubectl_manifest.temporal_root_ca]
}

# Frontend server cert — SANs pinned to the in-cluster service name (all three
# forms). Clients connect to temporal-frontend.<ns>.svc, so hostname
# verification passes with NO client-side server-name override (the reason
# intern's client.py needs no TLS changes).
resource "kubectl_manifest" "temporal_frontend_cert" {
  count = local.temporal_count

  yaml_body = yamlencode({
    apiVersion = "cert-manager.io/v1"
    kind       = "Certificate"
    metadata = {
      name      = "temporal-frontend-cert"
      namespace = local.temporal_namespace_k8s
    }
    spec = {
      secretName  = local.temporal_frontend_cert_secret
      duration    = "2160h" # 90d
      renewBefore = "720h"  # 30d
      privateKey  = { algorithm = "RSA", size = 2048 }
      usages      = ["digital signature", "key encipherment", "server auth"]
      dnsNames = [
        local.temporal_frontend_host,
        "${local.temporal_frontend_host}.cluster.local",
        local.temporal_frontend_service,
      ]
      issuerRef = {
        name  = "temporal-ca"
        kind  = "Issuer"
        group = "cert-manager.io"
      }
    }
  })

  server_side_apply = true
  force_conflicts   = true
  # Match Ready by condition TYPE, not by array position. During issuance a
  # Certificate carries BOTH Ready and Issuing, and nothing guarantees their order
  # within status.conditions, so indexing [0] can read Issuing=True and return
  # while the cert is still being issued — before the Secret exists. Upstream on
  # the Issuing condition: "It will be removed by the 'issuing' controller upon
  # completing issuance." (cert-manager pkg/apis/certmanager/v1/types_certificate.go)
  wait_for {
    condition {
      type   = "Ready"
      status = "True"
    }
  }
  depends_on = [kubectl_manifest.temporal_ca_issuer]
}

# Client certs (intern / Web UI / admin Jobs / system worker). cert-manager
# includes ca.crt in each secret, so every consumer mounts cert+key+CA from ONE
# secret.
resource "kubectl_manifest" "temporal_client_cert" {
  for_each = local.temporal_client_certs

  yaml_body = yamlencode({
    apiVersion = "cert-manager.io/v1"
    kind       = "Certificate"
    metadata = {
      name      = each.key
      namespace = local.temporal_namespace_k8s
    }
    spec = {
      secretName  = each.key
      commonName  = each.value
      duration    = "2160h" # 90d
      renewBefore = "720h"  # 30d
      privateKey  = { algorithm = "RSA", size = 2048 }
      usages      = ["digital signature", "key encipherment", "client auth"]
      issuerRef = {
        name  = "temporal-ca"
        kind  = "Issuer"
        group = "cert-manager.io"
      }
    }
  })

  server_side_apply = true
  force_conflicts   = true
  # Match Ready by condition TYPE, not by array position. During issuance a
  # Certificate carries BOTH Ready and Issuing, and nothing guarantees their order
  # within status.conditions, so indexing [0] can read Issuing=True and return
  # while the cert is still being issued — before the Secret exists. Upstream on
  # the Issuing condition: "It will be removed by the 'issuing' controller upon
  # completing issuance." (cert-manager pkg/apis/certmanager/v1/types_certificate.go)
  wait_for {
    condition {
      type   = "Ready"
      status = "True"
    }
  }
  depends_on = [kubectl_manifest.temporal_ca_issuer]
}

# -----------------------------------------------------------------------------
# 4a. DB bootstrap Job — psql as RDS master. Creates the two roles (ALTER ROLE
#     reconciles passwords on every run, so an ESO regeneration can't strand
#     the DB), both databases, the visibility statement_timeout, and the DML
#     grant surface for temporal_runtime (incl. default privileges for tables
#     the schema Jobs create later). Idempotent via \gexec + IF-EXISTS-free
#     conditional SELECTs.
#     Lifecycle (this Job + 4b): no TTL — the completed Job IS the execution
#     marker, so unchanged applies are no-ops. Any pod-spec change (script,
#     image, RDS endpoint) forces replace + re-run; password rotation is a
#     deliberate op (rotate the ESO generator secret, then taint this Job so
#     ALTER ROLE reconciles the DB).
# -----------------------------------------------------------------------------
resource "kubernetes_job_v1" "temporal_db_bootstrap" {
  count = local.temporal_count

  depends_on = [
    time_sleep.wait_for_temporal_rds,
    kubectl_manifest.temporal_rds_master_external_secret,
    kubectl_manifest.temporal_db_role_external_secret,
  ]

  metadata {
    name      = "pavo-temporal-db-bootstrap-${var.instance_id}"
    namespace = local.temporal_namespace_k8s
  }

  spec {
    backoff_limit = 3

    template {
      metadata {}
      spec {
        restart_policy = "Never"

        container {
          name    = "psql"
          image   = "public.ecr.aws/docker/library/postgres:16-alpine"
          command = ["/bin/sh", "-c"]
          args = [<<-EOT
            set -eu
            psql -v ON_ERROR_STOP=1 <<SQL
            SELECT 'CREATE ROLE temporal_schema_admin LOGIN' WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'temporal_schema_admin') \gexec
            SELECT 'CREATE ROLE temporal_runtime LOGIN' WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'temporal_runtime') \gexec
            ALTER ROLE temporal_schema_admin LOGIN PASSWORD '$SCHEMA_ADMIN_PW';
            ALTER ROLE temporal_runtime LOGIN PASSWORD '$RUNTIME_PW';
            GRANT temporal_schema_admin TO $PGUSER;
            SELECT 'CREATE DATABASE temporal OWNER temporal_schema_admin' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'temporal') \gexec
            SELECT 'CREATE DATABASE temporal_visibility OWNER temporal_schema_admin' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'temporal_visibility') \gexec
            -- Role-scoped, NOT DB-wide: the cap protects against runaway
            -- visibility QUERIES; a DB-wide setting would also kill the schema
            -- Job's long DDL (index builds) on future server upgrades.
            ALTER ROLE temporal_runtime IN DATABASE temporal_visibility SET statement_timeout = '15s';
            SQL
            for db in temporal temporal_visibility; do
              psql -v ON_ERROR_STOP=1 -d "$db" <<SQL
            GRANT USAGE ON SCHEMA public TO temporal_runtime;
            GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO temporal_runtime;
            GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO temporal_runtime;
            ALTER DEFAULT PRIVILEGES FOR ROLE temporal_schema_admin IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO temporal_runtime;
            ALTER DEFAULT PRIVILEGES FOR ROLE temporal_schema_admin IN SCHEMA public GRANT USAGE, SELECT ON SEQUENCES TO temporal_runtime;
            SQL
            done
            echo "Temporal DBs + roles ready."
          EOT
          ]
          env {
            name  = "PGHOST"
            value = aws_db_instance.temporal[0].address
          }
          env {
            name  = "PGPORT"
            value = tostring(aws_db_instance.temporal[0].port)
          }
          env {
            name  = "PGDATABASE"
            value = "postgres"
          }
          env {
            name  = "PGSSLMODE"
            value = "verify-full"
          }
          env {
            name  = "PGSSLROOTCERT"
            value = "/rds-ca/rds-ca.pem"
          }
          env {
            name = "PGUSER"
            value_from {
              secret_key_ref {
                name = local.temporal_rds_master_secret
                key  = "username"
              }
            }
          }
          env {
            name = "PGPASSWORD"
            value_from {
              secret_key_ref {
                name = local.temporal_rds_master_secret
                key  = "password"
              }
            }
          }
          env {
            name = "SCHEMA_ADMIN_PW"
            value_from {
              secret_key_ref {
                name = local.temporal_schema_db_secret
                key  = "password"
              }
            }
          }
          env {
            name = "RUNTIME_PW"
            value_from {
              secret_key_ref {
                name = local.temporal_runtime_db_secret
                key  = "password"
              }
            }
          }
          volume_mount {
            name       = "rds-ca"
            mount_path = "/rds-ca"
            read_only  = true
          }
        }

        volume {
          name = "rds-ca"
          config_map {
            name = kubernetes_config_map_v1.temporal_rds_ca[0].metadata[0].name
          }
        }
      }
    }
  }

  wait_for_completion = true
  timeouts {
    create = "10m"
    update = "10m"
  }
}

# -----------------------------------------------------------------------------
# 4b. Schema Job — temporal-sql-tool as temporal_schema_admin (DDL stays off
#     the runtime role). Same setup-schema + update-schema sequence the chart's
#     own hook runs (battle-tested idempotent). The image digest is part of the
#     pod spec, so a server/admin-tools version bump replaces + re-runs this Job
#     (update-schema is the upgrade path).
# -----------------------------------------------------------------------------
resource "kubernetes_job_v1" "temporal_schema_setup" {
  count = local.temporal_count

  depends_on = [
    kubernetes_job_v1.temporal_db_bootstrap,
    # First ghcr consumer in the chain: without the signature-pull secret the
    # cosign policy denies the pod at admission on first bring-up (zitadel
    # precedent) — everything later chains behind this Job.
    kubernetes_secret_v1.ghcr_signature_pull,
  ]

  metadata {
    name      = "pavo-temporal-schema-${var.instance_id}"
    namespace = local.temporal_namespace_k8s
  }

  spec {
    backoff_limit = 3

    template {
      metadata {}
      spec {
        restart_policy = "Never"
        node_selector  = local.temporal_node_selector
        image_pull_secrets {
          name = "pavo-ghcr-signature-pull"
        }

        container {
          name    = "schema"
          image   = local.temporal_admin_tools_image
          command = ["/bin/sh", "-c"]
          args = [<<-EOT
            set -eu
            export SQL_DATABASE=temporal
            temporal-sql-tool setup-schema -v 0.0
            temporal-sql-tool update-schema --schema-dir /etc/temporal/schema/postgresql/v12/temporal/versioned
            export SQL_DATABASE=temporal_visibility
            temporal-sql-tool setup-schema -v 0.0
            temporal-sql-tool update-schema --schema-dir /etc/temporal/schema/postgresql/v12/visibility/versioned
            echo "Temporal schemas ready."
          EOT
          ]
          env {
            name  = "SQL_PLUGIN"
            value = "postgres12_pgx"
          }
          env {
            name  = "SQL_HOST"
            value = aws_db_instance.temporal[0].address
          }
          env {
            name  = "SQL_PORT"
            value = tostring(aws_db_instance.temporal[0].port)
          }
          env {
            name = "SQL_USER"
            value_from {
              secret_key_ref {
                name = local.temporal_schema_db_secret
                key  = "username"
              }
            }
          }
          env {
            name = "SQL_PASSWORD"
            value_from {
              secret_key_ref {
                name = local.temporal_schema_db_secret
                key  = "password"
              }
            }
          }
          env {
            name  = "SQL_TLS"
            value = "true"
          }
          env {
            name  = "SQL_TLS_CA_FILE"
            value = "/rds-ca/rds-ca.pem"
          }
          volume_mount {
            name       = "rds-ca"
            mount_path = "/rds-ca"
            read_only  = true
          }
        }

        volume {
          name = "rds-ca"
          config_map {
            name = kubernetes_config_map_v1.temporal_rds_ca[0].metadata[0].name
          }
        }
      }
    }
  }

  wait_for_completion = true
  timeouts {
    create = "10m"
    update = "10m"
  }
}

# -----------------------------------------------------------------------------
# 5. Temporal server — temporalio/helm-charts 1.6.0, server components only.
#    web/admintools disabled (we run our own web pod; Jobs carry admin-tools).
#    schema.useHelmHooks=false + createDatabase/manageSchema=false: the chart
#    still renders a revision-named no-op "schema" Job (single `echo done`
#    container) — known chart limitation, harmless.
# -----------------------------------------------------------------------------
resource "helm_release" "temporal" {
  count = local.temporal_count

  name       = "temporal"
  repository = "https://go.temporal.io/helm-charts"
  chart      = "temporal"
  version    = "1.6.0"
  namespace  = local.temporal_namespace_k8s

  # Fresh install must not outlive the Omnistrate TF stage unnoticed; wait so
  # the namespace Job below only starts against a ready frontend.
  wait    = true
  timeout = 900

  values = [yamlencode({
    fullnameOverride = "temporal"
    imagePullSecrets = [{ name = "pavo-ghcr-signature-pull" }]

    server = {
      enabled = true
      image = {
        repository = local.temporal_server_image_repo
        tag        = local.temporal_server_image_tag
        pullPolicy = "IfNotPresent"
      }
      # HA: 2 replicas per role (2 history replicas over 128 shards is
      # standard), surge-only rollouts. Per-role PDB + hard spread come from
      # temporal_server_role_ha below.
      replicaCount = 2
      deploymentStrategy = {
        type = "RollingUpdate"
        rollingUpdate = {
          maxUnavailable = 0
          maxSurge       = 1
        }
      }
      nodeSelector = local.temporal_node_selector

      config = {
        logLevel = "info"

        persistence = {
          defaultStore     = "default"
          visibilityStore  = "visibility"
          numHistoryShards = var.temporal_history_shards

          datastores = {
            default = {
              sql = {
                createDatabase  = false
                manageSchema    = false
                pluginName      = "postgres12_pgx"
                databaseName    = "temporal"
                connectAddr     = "${aws_db_instance.temporal[0].address}:${aws_db_instance.temporal[0].port}"
                connectProtocol = "tcp"
                user            = "temporal_runtime"
                existingSecret  = local.temporal_runtime_db_secret
                maxConns        = 12
                maxIdleConns    = 6
                maxConnLifetime = "1h"
                tls = {
                  enabled                = true
                  enableHostVerification = true
                  caFile                 = "/etc/temporal/certs/rds/rds-ca.pem"
                }
              }
            }
            visibility = {
              sql = {
                createDatabase  = false
                manageSchema    = false
                pluginName      = "postgres12_pgx"
                databaseName    = "temporal_visibility"
                connectAddr     = "${aws_db_instance.temporal[0].address}:${aws_db_instance.temporal[0].port}"
                connectProtocol = "tcp"
                user            = "temporal_runtime"
                existingSecret  = local.temporal_runtime_db_secret
                maxConns        = 4
                maxIdleConns    = 2
                maxConnLifetime = "1h"
                tls = {
                  enabled                = true
                  enableHostVerification = true
                  caFile                 = "/etc/temporal/certs/rds/rds-ca.pem"
                }
              }
            }
          }
        }

        # Frontend mTLS: server cert + required client CA; internode stays
        # plaintext (in-cluster, same namespace). systemWorker presents its own
        # client cert; frontend.client covers every in-server frontend client.
        # refreshInterval hot-reloads cert-manager renewals.
        tls = {
          refreshInterval = "15m"
          frontend = {
            server = {
              certFile          = "/etc/temporal/certs/frontend/tls.crt"
              keyFile           = "/etc/temporal/certs/frontend/tls.key"
              requireClientAuth = true
              clientCaFiles     = ["/etc/temporal/certs/frontend/ca.crt"]
            }
            client = {
              serverName  = local.temporal_frontend_host
              rootCaFiles = ["/etc/temporal/certs/frontend/ca.crt"]
            }
          }
          systemWorker = {
            certFile = "/etc/temporal/certs/worker/tls.crt"
            keyFile  = "/etc/temporal/certs/worker/tls.key"
            # Explicit — a partially-set systemWorker block does not inherit
            # frontend.client in server 1.31.
            client = {
              serverName  = local.temporal_frontend_host
              rootCaFiles = ["/etc/temporal/certs/worker/ca.crt"]
            }
          }
        }
      }

      additionalVolumes = [
        {
          name   = "frontend-cert"
          secret = { secretName = local.temporal_frontend_cert_secret }
        },
        {
          name   = "worker-client-cert"
          secret = { secretName = "temporal-worker-client-cert" }
        },
        {
          name      = "rds-ca"
          configMap = { name = kubernetes_config_map_v1.temporal_rds_ca[0].metadata[0].name }
        },
      ]
      additionalVolumeMounts = [
        {
          name      = "frontend-cert"
          mountPath = "/etc/temporal/certs/frontend"
          readOnly  = true
        },
        {
          name      = "worker-client-cert"
          mountPath = "/etc/temporal/certs/worker"
          readOnly  = true
        },
        {
          name      = "rds-ca"
          mountPath = "/etc/temporal/certs/rds"
          readOnly  = true
        },
      ]

      frontend = merge(local.temporal_server_role_ha["frontend"], {
        resources = {
          requests = { cpu = "250m", memory = "512Mi" }
          limits   = { memory = "512Mi" }
        }
      })
      history = merge(local.temporal_server_role_ha["history"], {
        resources = {
          requests = { cpu = "500m", memory = "1Gi" }
          limits   = { memory = "1Gi" }
        }
      })
      matching = merge(local.temporal_server_role_ha["matching"], {
        resources = {
          requests = { cpu = "250m", memory = "512Mi" }
          limits   = { memory = "512Mi" }
        }
      })
      worker = merge(local.temporal_server_role_ha["worker"], {
        resources = {
          requests = { cpu = "250m", memory = "512Mi" }
          limits   = { memory = "512Mi" }
        }
        # Chart 1.6.0 gives the worker no probe at all; gate readiness on the
        # local metrics listener only — a Temporal API call here would create
        # synthetic traffic and a circular dependency.
        readinessProbe = {
          httpGet = {
            path = "/metrics"
            port = "metrics"
          }
          initialDelaySeconds = 15
          periodSeconds       = 10
        }
      })
    }

    # Off, but image pinned: the chart's no-op schema Job still renders and
    # runs this image's `echo done` container.
    admintools = {
      enabled = false
      image = {
        repository = local.temporal_admin_tools_image_repo
        tag        = local.temporal_admin_tools_image_tag
        pullPolicy = "IfNotPresent"
      }
      nodeSelector = local.temporal_node_selector
    }

    web = { enabled = false }

    schema = {
      useHelmHooks = false # required for Terraform-driven installs (chart docs)
    }

    # 1.31 images need no 1.29-compat shims
    shims = {
      dockerize         = false
      elasticsearchTool = false
    }
  })]

  depends_on = [
    kubernetes_job_v1.temporal_schema_setup,
    kubectl_manifest.temporal_frontend_cert,
    kubectl_manifest.temporal_client_cert,
  ]
}

# -----------------------------------------------------------------------------
# 4c. Namespace Job — registers pavo-<customer>-intern (retention 720h) once
#     the frontend is up. Runs over mTLS with the admin client cert, so a
#     successful connect IS the SAN + mTLS acceptance check (stronger than an
#     openssl probe). Retries stay inside the pod (backoff) to keep the TF
#     stage short. Unlike 4a/4b this Job keeps a TTL: it re-runs per apply
#     after the TTL window reaps the prior Job, reconciling retention (cheap,
#     idempotent).
# -----------------------------------------------------------------------------
resource "kubernetes_job_v1" "temporal_namespace_register" {
  count = local.temporal_count

  depends_on = [helm_release.temporal]

  metadata {
    name      = "pavo-temporal-namespace-${var.instance_id}"
    namespace = local.temporal_namespace_k8s
  }

  spec {
    backoff_limit              = 4
    ttl_seconds_after_finished = 600

    template {
      metadata {}
      spec {
        restart_policy = "Never"
        node_selector  = local.temporal_node_selector
        image_pull_secrets {
          name = "pavo-ghcr-signature-pull"
        }

        container {
          name    = "register"
          image   = local.temporal_admin_tools_image
          command = ["/bin/sh", "-c"]
          args = [<<-EOT
            set -eu
            temporal operator cluster health
            # Create ONLY on explicit NotFound — any other describe failure
            # (auth, transient) must fail the Job, not fall through to create.
            if out=$(temporal operator namespace describe "$NAMESPACE" 2>&1); then
              temporal operator namespace update --retention "$RETENTION" "$NAMESPACE"
              echo "namespace $NAMESPACE exists; retention reconciled to $RETENTION"
            elif echo "$out" | grep -qi "not found"; then
              temporal operator namespace create --retention "$RETENTION" "$NAMESPACE"
              echo "namespace $NAMESPACE created"
            else
              echo "namespace describe failed:" >&2
              echo "$out" >&2
              exit 1
            fi
          EOT
          ]
          env {
            name  = "TEMPORAL_ADDRESS"
            value = "${local.temporal_frontend_host}:${local.temporal_frontend_port}"
          }
          env {
            name  = "TEMPORAL_TLS_CERT"
            value = "/certs/tls.crt"
          }
          env {
            name  = "TEMPORAL_TLS_KEY"
            value = "/certs/tls.key"
          }
          env {
            name  = "TEMPORAL_TLS_CA"
            value = "/certs/ca.crt"
          }
          env {
            name  = "NAMESPACE"
            value = local.temporal_namespace
          }
          env {
            name  = "RETENTION"
            value = local.temporal_namespace_retention
          }
          volume_mount {
            name       = "admin-client-cert"
            mount_path = "/certs"
            read_only  = true
          }
        }

        volume {
          name = "admin-client-cert"
          secret {
            secret_name = "temporal-admin-client-cert"
          }
        }
      }
    }
  }

  wait_for_completion = true
  timeouts {
    create = "10m"
    update = "10m"
  }
}

# -----------------------------------------------------------------------------
# 6. temporal-web — UI (+ optional codec sidecar) behind an nginx basic-auth
#    sidecar. nginx's port is the ONLY one the Service/Ingress expose, so every
#    routed path — including the browser's same-origin /codec decode calls —
#    passes the credential gate. UI and codec both bind 127.0.0.1, so pod-IP
#    access from other in-cell pods dead-ends (the codec would otherwise be an
#    in-cluster decrypt oracle — this is why a sidecar and not ingress
#    basic-auth annotations).
# -----------------------------------------------------------------------------
resource "kubernetes_config_map_v1" "temporal_web_nginx" {
  count = local.temporal_count

  metadata {
    name      = "temporal-web-nginx"
    namespace = local.temporal_namespace_k8s
  }

  data = {
    "default.conf" = <<-EOT
      server {
        listen 8043;

        # Decode POSTs can approach the 2MB blob limit; both nginx layers
        # default to 1m (the ingress carries the matching proxy-body-size).
        client_max_body_size 8m;

        auth_basic "Pavo Temporal";
        auth_basic_user_file /etc/nginx/auth/htpasswd;

        # Unauthenticated liveness surface for kubelet only — static 200,
        # proxies nothing.
        location = /nginx-health {
          auth_basic off;
          return 200 "ok";
        }

        location / {
          proxy_pass http://127.0.0.1:8080;
          proxy_http_version 1.1;
          proxy_set_header Host $host;
          proxy_set_header X-Forwarded-Proto $scheme;
          proxy_buffering off;
          proxy_read_timeout 300s;
        }
      %{if local.temporal_codec_enabled}
        # Same-origin decode path for the browser (UI's TEMPORAL_CODEC_ENDPOINT
        # points here) — same basic-auth gate as the UI itself.
        location /codec/ {
          proxy_pass http://127.0.0.1:8090/;
          proxy_http_version 1.1;
          proxy_set_header Host $host;
        }
      %{endif}
      }
    EOT
  }
}

# ui-server config override. The stock image's config template has no env knob
# for the bind address (defaults to all interfaces), but the server honors
# `host` — mounting our own docker.yaml is the supported way
# (docker/start-ui-server.sh) to pin it to loopback. `# enable-template` keeps
# the upstream in-server env templating, so the container env below stays the
# interface. NOTE: the image's TLS env names are TEMPORAL_TLS_CERT/KEY/CA
# (paths), NOT *_PATH.
resource "kubernetes_config_map_v1" "temporal_web_ui_config" {
  count = local.temporal_count

  metadata {
    name      = "temporal-web-ui-config"
    namespace = local.temporal_namespace_k8s
  }

  data = {
    "docker.yaml" = <<-EOT
      # enable-template
      host: 127.0.0.1
      temporalGrpcAddress: {{ env "TEMPORAL_ADDRESS" }}
      port: {{ env "TEMPORAL_UI_PORT" | default "8080" }}
      enableUi: true
      defaultNamespace: {{ env "TEMPORAL_DEFAULT_NAMESPACE" }}
      tls:
        caFile: {{ env "TEMPORAL_TLS_CA" }}
        certFile: {{ env "TEMPORAL_TLS_CERT" }}
        keyFile: {{ env "TEMPORAL_TLS_KEY" }}
        serverName: {{ env "TEMPORAL_TLS_SERVER_NAME" }}
        enableHostVerification: true
      codec:
        endpoint: {{ env "TEMPORAL_CODEC_ENDPOINT" | default "" }}
    EOT
  }
}

resource "kubernetes_deployment_v1" "temporal_web" {
  count = local.temporal_count

  depends_on = [
    helm_release.temporal,
    kubectl_manifest.temporal_ui_auth_external_secret,
    kubectl_manifest.temporal_client_cert,
    kubernetes_secret_v1.temporal_codec_key,
  ]

  metadata {
    name      = "temporal-web"
    namespace = local.temporal_namespace_k8s
    labels    = local.temporal_web_labels
    annotations = {
      # cert-manager renews the UI client cert ~day 60; the cell-wide Stakater
      # reloader restarts this Deployment so mTLS to the frontend keeps working.
      "secret.reloader.stakater.com/reload" = join(",", concat(
        ["temporal-ui-client-cert"],
        local.temporal_codec_enabled ? [local.temporal_codec_key_secret] : [],
      ))
    }
  }

  spec {
    replicas = 1
    selector {
      match_labels = local.temporal_web_labels
    }
    template {
      metadata {
        labels = local.temporal_web_labels
        annotations = {
          # ConfigMap edits alone don't restart the pod (nginx/ui-server read
          # config once at start); checksum change forces a rollout.
          "checksum/nginx-conf" = sha256(kubernetes_config_map_v1.temporal_web_nginx[0].data["default.conf"])
          "checksum/ui-config"  = sha256(kubernetes_config_map_v1.temporal_web_ui_config[0].data["docker.yaml"])
        }
      }
      spec {
        node_selector = local.temporal_node_selector
        image_pull_secrets {
          name = "pavo-ghcr-signature-pull"
        }

        # --- nginx auth sidecar: the single exposed port -------------------
        container {
          name  = "nginx"
          image = local.temporal_nginx_image
          port {
            name           = "http"
            container_port = 8043
          }
          volume_mount {
            name       = "nginx-conf"
            mount_path = "/etc/nginx/conf.d"
            read_only  = true
          }
          volume_mount {
            name       = "ui-auth"
            mount_path = "/etc/nginx/auth"
            read_only  = true
          }
          readiness_probe {
            http_get {
              path = "/nginx-health"
              port = 8043
            }
            initial_delay_seconds = 5
            period_seconds        = 10
            failure_threshold     = 6
          }
          resources {
            requests = {
              cpu    = "25m"
              memory = "32Mi"
            }
            limits = {
              memory = "64Mi"
            }
          }
        }

        # --- Temporal Web UI (pod-local) -----------------------------------
        container {
          name  = "ui"
          image = local.temporal_ui_image
          env {
            name  = "TEMPORAL_ADDRESS"
            value = "${local.temporal_frontend_host}:${local.temporal_frontend_port}"
          }
          env {
            name  = "TEMPORAL_UI_PORT"
            value = "8080"
          }
          env {
            name  = "TEMPORAL_DEFAULT_NAMESPACE"
            value = local.temporal_namespace
          }
          env {
            name  = "TEMPORAL_TLS_CERT"
            value = "/certs/tls.crt"
          }
          env {
            name  = "TEMPORAL_TLS_KEY"
            value = "/certs/tls.key"
          }
          env {
            name  = "TEMPORAL_TLS_CA"
            value = "/certs/ca.crt"
          }
          env {
            name  = "TEMPORAL_TLS_SERVER_NAME"
            value = local.temporal_frontend_host
          }
          dynamic "env" {
            for_each = local.temporal_codec_enabled ? [1] : []
            content {
              name  = "TEMPORAL_CODEC_ENDPOINT"
              value = "https://${local.temporal_web_host}/codec"
            }
          }
          volume_mount {
            name       = "ui-client-cert"
            mount_path = "/certs"
            read_only  = true
          }
          volume_mount {
            name       = "ui-config"
            mount_path = "/home/ui-server/config/docker.yaml"
            sub_path   = "docker.yaml"
            read_only  = true
          }
          # Gates Service routing on the UI process actually serving (it
          # returns 200 regardless of frontend reachability) — nginx's own
          # probe only proves nginx is up. exec (not httpGet): the UI binds
          # loopback, so the kubelet can't reach it via the pod IP.
          readiness_probe {
            exec {
              command = ["wget", "-q", "-O", "/dev/null", "http://127.0.0.1:8080/"]
            }
            initial_delay_seconds = 10
            period_seconds        = 10
            failure_threshold     = 6
          }
          resources {
            requests = {
              cpu    = "50m"
              memory = "128Mi"
            }
            limits = {
              memory = "256Mi"
            }
          }
        }

        # --- payload codec server (pod-local; only when key + image set) ---
        dynamic "container" {
          for_each = local.temporal_codec_enabled ? [1] : []
          content {
            name    = "codec"
            image   = var.temporal_codec_image
            command = ["python", "-m", "temporal.codec.server"]
            env {
              name  = "CODEC_SERVER_HOST"
              value = "127.0.0.1"
            }
            env {
              name  = "CODEC_SERVER_PORT"
              value = "8090"
            }
            env {
              name = "TEMPORAL_PAYLOAD_CODEC_KEY"
              value_from {
                secret_key_ref {
                  name = local.temporal_codec_key_secret
                  key  = "TEMPORAL_PAYLOAD_CODEC_KEY"
                }
              }
            }
            # Loopback bind → kubelet can't httpGet it; exec with the image's
            # own python (always present — it runs the server).
            readiness_probe {
              exec {
                command = ["python", "-c", "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8090/health', timeout=3).status == 200 else 1)"]
              }
              initial_delay_seconds = 5
              period_seconds        = 10
              failure_threshold     = 6
            }
            resources {
              requests = {
                cpu    = "50m"
                memory = "128Mi"
              }
              limits = {
                memory = "256Mi"
              }
            }
          }
        }

        volume {
          name = "nginx-conf"
          config_map {
            name = kubernetes_config_map_v1.temporal_web_nginx[0].metadata[0].name
          }
        }
        volume {
          name = "ui-auth"
          secret {
            secret_name = local.temporal_ui_auth_secret
            items {
              key  = "htpasswd"
              path = "htpasswd"
            }
          }
        }
        volume {
          name = "ui-client-cert"
          secret {
            secret_name = "temporal-ui-client-cert"
          }
        }
        volume {
          name = "ui-config"
          config_map {
            name = kubernetes_config_map_v1.temporal_web_ui_config[0].metadata[0].name
          }
        }
      }
    }
  }
}

resource "kubernetes_service_v1" "temporal_web" {
  count = local.temporal_count

  metadata {
    name      = "temporal-web"
    namespace = local.temporal_namespace_k8s
    labels    = local.temporal_web_labels
  }
  spec {
    selector = local.temporal_web_labels
    port {
      name        = "http"
      port        = 8043
      target_port = 8043
    }
  }
}

# In-VPC-posture ingress: pavo-nginx (cell-scoped, from pavo-bootstrap-aws).
# On a strict cell (network_posture=strict) this is VPC-only, same as
# Grafana/Kibana — network lock + the basic-auth credential lock above.
resource "kubernetes_ingress_v1" "temporal_web" {
  count = local.temporal_count

  metadata {
    name      = "temporal-web"
    namespace = local.temporal_namespace_k8s
    annotations = {
      "cert-manager.io/cluster-issuer" = "pavo-letsencrypt-prod"
      # Match the sidecar's client_max_body_size for /codec decode POSTs.
      "nginx.ingress.kubernetes.io/proxy-body-size" = "8m"
    }
  }
  spec {
    ingress_class_name = "pavo-nginx"
    tls {
      hosts       = [local.temporal_web_host]
      secret_name = "temporal-web-tls"
    }
    rule {
      host = local.temporal_web_host
      http {
        path {
          path      = "/"
          path_type = "Prefix"
          backend {
            service {
              name = kubernetes_service_v1.temporal_web[0].metadata[0].name
              port {
                number = 8043
              }
            }
          }
        }
      }
    }
  }
}
