# =============================================================================
# Self-hosted Zitadel (in-VPC identity) — per-instance
# =============================================================================
# Materializes ONLY when zitadel_mode = "self_hosted". Default zitadel_mode =
# "cloud" (the shared central Zitadel via pavo-customer-bootstrap pass-through
# vars) is completely unchanged — every resource here is count-gated on
# local.zitadel_count, so this file is purely additive and touches nothing on
# the existing cloud path.
#
# Steps implemented here (all live-validated on an internal test instance via throwaway spikes):
#   Step 1 — flag gate + resolved auth host + in-cluster secrets (masterkey +
#            zitadel DB password, ESO generate-once, never in TF state).
#   Step 2 — `zitadel-db-credentials` (DB + least-priv role created by
#            `zitadel init` in the Setup Job; rides the customer CMK, no new KMS).
#   Step 3 — Setup Job: `zitadel init` → `setup` (FirstInstance → customer org +
#            provisioner machine KEY) → persist the key to a scoped Secret.
#   Step 4 — Zitadel Deployment (2 replicas, serves internal HTTPS so callers
#            never spoof X-Forwarded-Proto) + PDB + Service + Ingress + the
#            cert-manager self-signed cert it serves.
#
# The Provision Job (Step 5), Readiness (Step 7), and the api-gateway / frontend
# / spec-byoc runtime rewire (Step 6) land separately.
#
# KISS/DEV note: masterkey custody here is the throwaway ESO generate-once
# pattern (INV-2 — losing the Secret loses the DEV identity, accepted). The
# durable Secrets-Manager custody + the DB-state-aware regeneration guard are
# part of the prod/strict follow-up, not this DEV foundation.

locals {
  zitadel_self_hosted = var.zitadel_mode == "self_hosted"
  zitadel_count       = local.zitadel_self_hosted ? 1 : 0

  zitadel_namespace = var.instance_id

  # Resolved public auth host: the explicit auth_hostname if set, else the
  # auto-derived `auth.<customer_name>.<base_domain>`. Safe to derive because
  # customer_name is unique/stable (never reused) and matches the app host
  # convention `<customer_name>.<base_domain>`. Consumed by the Deployment /
  # Ingress / issuer wiring in Steps 4-6.
  zitadel_auth_host = var.auth_hostname != "" ? var.auth_hostname : "auth.${var.customer_name}.${var.base_domain}"

  # Canonical in-cluster object names (single source of truth — reused verbatim
  # by the later steps and the runtime wiring).
  zitadel_masterkey_secret   = "zitadel-masterkey"
  zitadel_db_secret          = "zitadel-db-credentials"
  zitadel_masterkey_gen_name = "zitadel-masterkey"
  zitadel_db_pw_gen_name     = "zitadel-db-password"
}

# -----------------------------------------------------------------------------
# Step 1 — in-cluster generated secrets (ESO Password generators)
# -----------------------------------------------------------------------------
# Both values are generated in-cluster by ESO and NEVER enter Terraform state.
# refreshInterval "0" on the consuming ExternalSecret = generate-once (proven
# stable across operator restart / TF re-apply / metadata update — only a
# force-sync regenerates, so never force-sync these; ignore_changes guards
# against drift-rotation). symbols = 0 keeps both values [A-Za-z0-9]: a clean
# 32-byte Zitadel masterkey and a DB password with no URL/psql-quoting hazards.

resource "kubectl_manifest" "zitadel_masterkey_generator" {
  count = local.zitadel_count

  yaml_body = yamlencode({
    apiVersion = "generators.external-secrets.io/v1alpha1"
    kind       = "Password"
    metadata = {
      name      = local.zitadel_masterkey_gen_name
      namespace = local.zitadel_namespace
    }
    # Zitadel requires a masterkey of EXACTLY 32 bytes; 32 ASCII chars = 32 bytes.
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

resource "kubectl_manifest" "zitadel_db_password_generator" {
  count = local.zitadel_count

  yaml_body = yamlencode({
    apiVersion = "generators.external-secrets.io/v1alpha1"
    kind       = "Password"
    metadata = {
      name      = local.zitadel_db_pw_gen_name
      namespace = local.zitadel_namespace
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

# masterkey → Secret `zitadel-masterkey` (key: masterkey). Consumed by the
# Setup Job (`zitadel setup --masterkeyFromEnv`) and the Deployment in Step 3/4.
resource "kubectl_manifest" "zitadel_masterkey_external_secret" {
  count = local.zitadel_count

  yaml_body = yamlencode({
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ExternalSecret"
    metadata = {
      name      = local.zitadel_masterkey_secret
      namespace = local.zitadel_namespace
    }
    spec = {
      refreshInterval = "0"
      target = {
        name           = local.zitadel_masterkey_secret
        creationPolicy = "Owner"
        template = {
          engineVersion = "v2"
          data = {
            masterkey = "{{ .password }}"
          }
        }
      }
      dataFrom = [{
        sourceRef = {
          generatorRef = {
            apiVersion = "generators.external-secrets.io/v1alpha1"
            kind       = "Password"
            name       = local.zitadel_masterkey_gen_name
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
    kubectl_manifest.zitadel_masterkey_generator,
  ]
}

# -----------------------------------------------------------------------------
# Step 2 — the `zitadel` DB credentials (DB + role created by `zitadel init`)
# -----------------------------------------------------------------------------
# The generated DB password + the Terraform-known RDS coordinates are combined
# into `zitadel-db-credentials` with discrete ZITADEL_DATABASE_POSTGRES_* keys.
# The dedicated `zitadel` DB + least-priv role are created by `zitadel init`
# (Setup Job, Step 3) using these USER creds + the RDS master as ADMIN — spike-
# validated, so no custom psql job (KISS). INV-5 holds: master creds appear only
# in the Setup Job's init container; runtime uses this least-priv `zitadel` user;
# dedicated DB. Encryption is FREE: the `zitadel` DB lives on the existing
# per-instance RDS, already storage_encrypted under the customer CMK
# (aws_db_instance.postgres kms_key_id = var.cell_kms_key_arn) — no new KMS key.
# The Zitadel masterkey is a separate application-layer column encryption.
resource "kubectl_manifest" "zitadel_db_credentials_external_secret" {
  count = local.zitadel_count

  yaml_body = yamlencode({
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ExternalSecret"
    metadata = {
      name      = local.zitadel_db_secret
      namespace = local.zitadel_namespace
    }
    spec = {
      refreshInterval = "0"
      target = {
        name           = local.zitadel_db_secret
        creationPolicy = "Owner"
        template = {
          engineVersion = "v2"
          data = {
            ZITADEL_DATABASE_POSTGRES_HOST          = aws_db_instance.postgres.address
            ZITADEL_DATABASE_POSTGRES_PORT          = tostring(aws_db_instance.postgres.port)
            ZITADEL_DATABASE_POSTGRES_DATABASE      = "zitadel"
            ZITADEL_DATABASE_POSTGRES_USER_USERNAME = "zitadel"
            ZITADEL_DATABASE_POSTGRES_USER_PASSWORD = "{{ .password }}"
          }
        }
      }
      dataFrom = [{
        sourceRef = {
          generatorRef = {
            apiVersion = "generators.external-secrets.io/v1alpha1"
            kind       = "Password"
            name       = local.zitadel_db_pw_gen_name
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
    kubectl_manifest.zitadel_db_password_generator,
    aws_db_instance.postgres,
  ]
}

# -----------------------------------------------------------------------------
# Steps 3-4 locals (images spike-pinned by digest; stock images are admitted by
# the cell Sigstore policy — no-match=allow, only ghcr.io/pavoai/** is enforced)
# -----------------------------------------------------------------------------
locals {
  # Zitadel v2.71.19 (multi-arch index digest).
  zitadel_image = "ghcr.io/zitadel/zitadel@sha256:32834d46240c5ece9f86c5e5f706b167c2064fba76bbf9213e3494023c38ca5d"
  # alpine/k8s 1.31.0 — kubectl + shell, for the key-persist step.
  zitadel_kubectl_image      = "docker.io/alpine/k8s@sha256:66dd3f7db6c4cf152b688d83aad11ceed9eb2da0c4e7de1034c7d4ccea1b55ef"
  zitadel_replicas           = 2
  zitadel_provisioner_secret = "zitadel-provisioner-credential"

  zitadel_labels = {
    "app.kubernetes.io/name"     = "zitadel"
    "app.kubernetes.io/instance" = var.instance_id
  }

  # Pin the whole zitadel stack to the amd64 workload nodegroup (t3.2xlarge),
  # matching the app services' nodeSelector in spec-byoc.yaml. Required because
  # the zitadel-provisioner image is amd64-only: without this, pods fall to the
  # Omnistrate DEFAULT nodegroup — which is arm64 (t4g) — and the provisioner
  # image fails (exec-format). Also keeps the Zitadel Deployment off the small
  # arm64 system nodes. TEMPORARY: drop once the images go multi-arch (tracked).
  zitadel_node_selector = {
    "node.kubernetes.io/instance-type" = "t3.2xlarge"
  }
}

# =============================================================================
# Step 3 — Setup Job: init → setup → persist provisioner machine key
# =============================================================================
# Runs ONCE before the Deployment (Step 4), so multi-replica `zitadel start` is
# safe. Sequence (spike-validated, F7/F8):
#   initContainer `zitadel-init`  (ADMIN=RDS master) creates the zitadel DB+role
#   initContainer `zitadel-setup` (FirstInstance)    creates instance + customer
#                                                     org + provisioner machine
#                                                     user + emits its KEY JSON
#   container     `persist-key`   copies the KEY JSON into a scoped K8s Secret
#                                 (idempotent; retries the write in-process so a
#                                  transient API error can't forfeit the one-shot
#                                  key — fail-hard only if truly gone — F8).

resource "kubernetes_service_account_v1" "zitadel_setup" {
  count = local.zitadel_count
  metadata {
    name      = "zitadel-setup"
    namespace = local.zitadel_namespace
  }
}

resource "kubernetes_role_v1" "zitadel_setup" {
  count = local.zitadel_count
  metadata {
    name      = "zitadel-setup"
    namespace = local.zitadel_namespace
  }
  # Least-priv: only the provisioner-credential secret, only create/get/patch.
  rule {
    api_groups = [""]
    resources  = ["secrets"]
    verbs      = ["get", "create", "patch"]
  }
}

resource "kubernetes_role_binding_v1" "zitadel_setup" {
  count = local.zitadel_count
  metadata {
    name      = "zitadel-setup"
    namespace = local.zitadel_namespace
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role_v1.zitadel_setup[0].metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.zitadel_setup[0].metadata[0].name
    namespace = local.zitadel_namespace
  }
}

resource "kubernetes_job_v1" "zitadel_setup" {
  count = local.zitadel_count

  depends_on = [
    time_sleep.wait_for_rds,
    kubectl_manifest.external_secret_db_credentials,         # RDS master creds (ADMIN)
    kubectl_manifest.zitadel_db_credentials_external_secret, # zitadel USER creds
    kubectl_manifest.zitadel_masterkey_external_secret,      # masterkey
    kubernetes_role_binding_v1.zitadel_setup,
  ]

  metadata {
    name      = "pavo-zitadel-setup-${var.instance_id}"
    namespace = local.zitadel_namespace
  }

  spec {
    backoff_limit              = 3
    ttl_seconds_after_finished = 600

    template {
      metadata {}
      spec {
        enable_service_links = false # F1: avoid ZITADEL_PORT Service-link collision
        node_selector        = local.zitadel_node_selector
        service_account_name = kubernetes_service_account_v1.zitadel_setup[0].metadata[0].name
        restart_policy       = "Never"

        # --- init: create the zitadel DB + least-priv role (ADMIN = RDS master) ---
        init_container {
          name    = "zitadel-init"
          image   = local.zitadel_image
          command = ["/app/zitadel", "init"]
          env_from {
            secret_ref { name = local.zitadel_db_secret } # USER host/port/db/user/pw
          }
          env {
            name = "ZITADEL_DATABASE_POSTGRES_ADMIN_USERNAME"
            value_from {
              secret_key_ref {
                name = "pavo-rds-db-credentials"
                key  = "username"
              }
            }
          }
          env {
            name = "ZITADEL_DATABASE_POSTGRES_ADMIN_PASSWORD"
            value_from {
              secret_key_ref {
                name = "pavo-rds-db-credentials"
                key  = "password"
              }
            }
          }
          env {
            name  = "ZITADEL_DATABASE_POSTGRES_ADMIN_SSL_MODE"
            value = "require"
          }
          env {
            name  = "ZITADEL_DATABASE_POSTGRES_USER_SSL_MODE"
            value = "require"
          }
        }

        # --- setup: FirstInstance → instance + customer org + provisioner key ---
        init_container {
          name    = "zitadel-setup"
          image   = local.zitadel_image
          command = ["/app/zitadel", "setup", "--masterkeyFromEnv", "--init-projections=true"]
          env_from {
            secret_ref { name = local.zitadel_db_secret }
          }
          env {
            name = "ZITADEL_MASTERKEY"
            value_from {
              secret_key_ref {
                name = local.zitadel_masterkey_secret
                key  = "masterkey"
              }
            }
          }
          env {
            name  = "ZITADEL_DATABASE_POSTGRES_USER_SSL_MODE"
            value = "require"
          }
          # Public-issuer identity (F9: issuer scheme comes from these + XFP).
          env {
            name  = "ZITADEL_EXTERNALDOMAIN"
            value = local.zitadel_auth_host
          }
          env {
            name  = "ZITADEL_EXTERNALPORT"
            value = "443"
          }
          env {
            name  = "ZITADEL_EXTERNALSECURE"
            value = "true"
          }
          env {
            name  = "ZITADEL_TLS_ENABLED"
            value = "false"
          }
          # FirstInstance → a throwaway SYSTEM org that only homes the IAM_OWNER
          # provisioner machine user. The CUSTOMER org (var.customer_name) is
          # created fresh + owned by the Provision Job's Terraform (import-free
          # model — no fragile org_id resolution). The machine user is IAM_OWNER
          # (instance-wide), so it can create + manage the customer org.
          env {
            name  = "ZITADEL_FIRSTINSTANCE_ORG_NAME"
            value = "pavo-system"
          }
          env {
            name  = "ZITADEL_FIRSTINSTANCE_ORG_MACHINE_MACHINE_USERNAME"
            value = "terraform-provisioner"
          }
          env {
            name  = "ZITADEL_FIRSTINSTANCE_ORG_MACHINE_MACHINE_NAME"
            value = "Terraform Provisioner"
          }
          env {
            name  = "ZITADEL_FIRSTINSTANCE_ORG_MACHINE_MACHINEKEY_TYPE"
            value = "1" # JSON key
          }
          env {
            name  = "ZITADEL_FIRSTINSTANCE_MACHINEKEYPATH"
            value = "/keys/sa.json"
          }
          volume_mount {
            name       = "keys"
            mount_path = "/keys"
          }
        }

        # --- persist: KEY JSON → scoped Secret (idempotent; retried) ----------
        # The emitted key lives ONLY on this pod's emptyDir and CANNOT be
        # re-emitted (FirstInstance is one-shot). So a transient API-server error
        # on the write must NOT fail the pod: that would start a fresh pod whose
        # setup step, seeing an already-initialized instance, emits no key and
        # wedges the instance into a manual DB+masterkey reset. We retry the write
        # in-process (key still on the emptyDir) and only fail-hard once the key is
        # genuinely unrecoverable (secret absent AND no key file).
        container {
          name    = "persist-key"
          image   = local.zitadel_kubectl_image
          command = ["/bin/sh", "-c"]
          args = [<<-EOT
            set -eu
            if kubectl -n "$NS" get secret "$SECRET" >/dev/null 2>&1; then
              echo "provisioner credential already exists — skip"; exit 0
            fi
            if [ ! -s /keys/sa.json ]; then
              echo "FATAL: provisioner credential missing but Zitadel is initialized — the machine key is emitted only on FirstInstance. Reset the zitadel DB + masterkey together and rerun." >&2
              exit 1
            fi
            for attempt in 1 2 3 4 5; do
              if kubectl -n "$NS" create secret generic "$SECRET" --from-file=sa.json=/keys/sa.json; then
                echo "created $SECRET"; exit 0
              fi
              # A partial/racing create may already have landed the secret.
              if kubectl -n "$NS" get secret "$SECRET" >/dev/null 2>&1; then
                echo "provisioner credential now exists — done"; exit 0
              fi
              echo "persist attempt $attempt failed — retrying in 5s" >&2
              sleep 5
            done
            echo "FATAL: could not persist the provisioner credential after retries; the machine key is emitted only on FirstInstance. Reset the zitadel DB + masterkey together and rerun." >&2
            exit 1
          EOT
          ]
          env {
            name  = "NS"
            value = local.zitadel_namespace
          }
          env {
            name  = "SECRET"
            value = local.zitadel_provisioner_secret
          }
          volume_mount {
            name       = "keys"
            mount_path = "/keys"
          }
        }

        volume {
          name = "keys"
          empty_dir {}
        }
      }
    }
  }

  wait_for_completion = true
  timeouts {
    create = "15m"
    update = "15m"
  }
}

# =============================================================================
# Step 4 — Zitadel Deployment (HA) + Service + Ingress
# =============================================================================

# Internal TLS (F10): a cert-manager self-signed Issuer mints the cert Zitadel
# serves on :8080, so every in-cluster caller connects over real HTTPS (no XFP
# spoofing, no proxy sidecar). In-cluster callers skip-verify this cert; the
# public browser path is fronted by the LE cert on the Ingress. Key never enters
# TF state; auto-renewed by cert-manager.
resource "kubectl_manifest" "zitadel_selfsigned_issuer" {
  count = local.zitadel_count
  yaml_body = yamlencode({
    apiVersion = "cert-manager.io/v1"
    kind       = "Issuer"
    metadata = {
      name      = "zitadel-selfsigned"
      namespace = local.zitadel_namespace
    }
    spec = { selfSigned = {} }
  })
  server_side_apply = true
  force_conflicts   = true
  depends_on        = [kubectl_manifest.instance_namespace]
}

resource "kubectl_manifest" "zitadel_internal_cert" {
  count = local.zitadel_count
  yaml_body = yamlencode({
    apiVersion = "cert-manager.io/v1"
    kind       = "Certificate"
    metadata = {
      name      = "zitadel-internal-tls"
      namespace = local.zitadel_namespace
    }
    spec = {
      secretName  = "zitadel-internal-tls"
      duration    = "2160h" # 90d
      renewBefore = "360h"  # 15d
      privateKey  = { algorithm = "RSA", size = 2048 }
      dnsNames = [
        local.zitadel_auth_host,
        "zitadel.${local.zitadel_namespace}.svc",
        "zitadel.${local.zitadel_namespace}.svc.cluster.local",
        "zitadel",
      ]
      issuerRef = {
        name  = "zitadel-selfsigned"
        kind  = "Issuer"
        group = "cert-manager.io"
      }
    }
  })
  server_side_apply = true
  force_conflicts   = true
  # Block until cert-manager has issued the secret, so the Deployment can mount it.
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
  depends_on = [kubectl_manifest.zitadel_selfsigned_issuer]
}

resource "kubernetes_deployment_v1" "zitadel" {
  count = local.zitadel_count
  depends_on = [
    kubernetes_job_v1.zitadel_setup,        # DB is setup-initialized first
    kubectl_manifest.zitadel_internal_cert, # internal TLS secret exists
  ]

  metadata {
    name      = "zitadel"
    namespace = local.zitadel_namespace
    labels    = local.zitadel_labels
  }

  spec {
    replicas = local.zitadel_replicas
    selector {
      match_labels = local.zitadel_labels
    }
    template {
      metadata {
        labels = local.zitadel_labels
      }
      spec {
        enable_service_links = false # F1 (critical): ZITADEL_PORT Service-link collision
        node_selector        = local.zitadel_node_selector

        # Soft anti-affinity in DEV — required would risk an unschedulable 2nd
        # replica on a small node pool (prod flips this to required).
        affinity {
          pod_anti_affinity {
            preferred_during_scheduling_ignored_during_execution {
              weight = 100
              pod_affinity_term {
                topology_key = "kubernetes.io/hostname"
                label_selector {
                  match_labels = local.zitadel_labels
                }
              }
            }
          }
        }

        container {
          name    = "zitadel"
          image   = local.zitadel_image
          command = ["/app/zitadel", "start", "--masterkeyFromEnv"]

          env_from {
            secret_ref { name = local.zitadel_db_secret } # USER host/port/db/user/pw
          }
          env {
            name = "ZITADEL_MASTERKEY"
            value_from {
              secret_key_ref {
                name = local.zitadel_masterkey_secret
                key  = "masterkey"
              }
            }
          }
          env {
            name  = "ZITADEL_DATABASE_POSTGRES_USER_SSL_MODE"
            value = "require"
          }
          env {
            name  = "ZITADEL_EXTERNALDOMAIN"
            value = local.zitadel_auth_host
          }
          env {
            name  = "ZITADEL_EXTERNALPORT"
            value = "443"
          }
          env {
            name  = "ZITADEL_EXTERNALSECURE"
            value = "true"
          }
          # Serve REAL HTTPS internally (F10): callers connect over TLS with just
          # the Host header → https issuer, no X-Forwarded-Proto spoofing and no
          # proxy sidecar anywhere. Cert from the cert-manager self-signed Issuer.
          env {
            name  = "ZITADEL_TLS_ENABLED"
            value = "true"
          }
          env {
            name  = "ZITADEL_TLS_CERTPATH"
            value = "/certs/tls.crt"
          }
          env {
            name  = "ZITADEL_TLS_KEYPATH"
            value = "/certs/tls.key"
          }
          # Small per-replica pool (2 replicas share the instance RDS).
          env {
            name  = "ZITADEL_DATABASE_POSTGRES_MAXOPENCONNS"
            value = "10"
          }

          port {
            name           = "https"
            container_port = 8080
          }

          volume_mount {
            name       = "internal-tls"
            mount_path = "/certs"
            read_only  = true
          }

          readiness_probe {
            http_get {
              path   = "/debug/healthz"
              port   = 8080
              scheme = "HTTPS"
            }
            initial_delay_seconds = 10
            period_seconds        = 5
            failure_threshold     = 12
          }
          liveness_probe {
            http_get {
              path   = "/debug/healthz"
              port   = 8080
              scheme = "HTTPS"
            }
            initial_delay_seconds = 30
            period_seconds        = 15
            failure_threshold     = 6
          }

          resources {
            requests = {
              cpu    = "100m"
              memory = "256Mi"
            }
            limits = {
              memory = "1Gi"
            }
          }
        }

        volume {
          name = "internal-tls"
          secret {
            secret_name = "zitadel-internal-tls"
          }
        }
      }
    }
  }
}

resource "kubernetes_pod_disruption_budget_v1" "zitadel" {
  count = local.zitadel_count
  metadata {
    name      = "zitadel"
    namespace = local.zitadel_namespace
  }
  spec {
    min_available = 1
    selector {
      match_labels = local.zitadel_labels
    }
  }
}

resource "kubernetes_service_v1" "zitadel" {
  count = local.zitadel_count
  metadata {
    name      = "zitadel"
    namespace = local.zitadel_namespace
    labels    = local.zitadel_labels
  }
  spec {
    selector = local.zitadel_labels
    port {
      name        = "https"
      port        = 8080
      target_port = 8080
    }
  }
}

# Ingress — public browser/OIDC path only (the gRPC management API + api-gateway
# OIDC calls use the internal ClusterIP svc, not this ingress). pavo-nginx +
# Let's Encrypt (both cell-scoped, from pavo-bootstrap-aws).
resource "kubernetes_ingress_v1" "zitadel" {
  count = local.zitadel_count
  metadata {
    name      = "zitadel"
    namespace = local.zitadel_namespace
    annotations = {
      "cert-manager.io/cluster-issuer" = "pavo-letsencrypt-prod"
      # Zitadel serves HTTPS internally (F10) — nginx must re-encrypt to the
      # backend. proxy_ssl_verify is off by default, so the self-signed backend
      # cert is accepted.
      "nginx.ingress.kubernetes.io/backend-protocol" = "HTTPS"
    }
  }
  spec {
    ingress_class_name = "pavo-nginx"
    tls {
      hosts       = [local.zitadel_auth_host]
      secret_name = "zitadel-tls"
    }
    rule {
      host = local.zitadel_auth_host
      http {
        path {
          path      = "/"
          path_type = "Prefix"
          backend {
            service {
              name = kubernetes_service_v1.zitadel[0].metadata[0].name
              port {
                number = 8080
              }
            }
          }
        }
      }
    }
  }
}
