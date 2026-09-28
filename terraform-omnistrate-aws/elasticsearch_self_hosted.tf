# =============================================================================
# Self-hosted Elasticsearch (ECK) — per-instance (C2)
# =============================================================================
# Materializes ONLY when es_mode = "self_hosted". Default es_mode = "cloud"
# (Elastic Cloud via ec_deployment) is completely unchanged — every resource
# here is count-gated, so this file is purely additive and touches nothing on
# the existing cloud path. Validated end-to-end on an internal test instance in
# the Phase 0 spike.
#
# C2 (this file) — the cluster + its identity:
#   - CMK gp3 StorageClass (EBS at rest under the customer CMK)
#   - ESO Password generators + ExternalSecrets for 3 least-priv fileRealm users
#   - roles.yml secret (native ES role definitions)
#   - Elasticsearch CR (1 node, 0 replicas, ClusterIP, IRSA pod template)
#   - snapshot IRSA role + pavo-es ServiceAccount (pod identity; S3/KMS policy +
#     bucket + bootstrap Job come in C3)
#   - ES-scoped NetworkPolicy
#   - elasticsearch_exporter (monitor-only)
#
# NOTE: needs the cell to have ECK installed (pavo-bootstrap-aws var.enable_eck),
# and the EBS CSI role to hold the customer-CMK KMS grant (separate PR) for the
# data volume to actually provision. Both are deploy-time deps, not code deps.

locals {
  es_self_hosted = var.es_mode == "self_hosted"
  es_count       = local.es_self_hosted ? 1 : 0

  es_name      = "pavo-es"
  es_namespace = var.instance_id
  es_version   = "8.19.5"

  # Kibana (the ES UI) — same gate as ES. Rides the pavo-nginx app ingress at
  # kibana.<customer_name>.<base_domain>, so its public/internal exposure follows
  # network_posture exactly like Grafana/frontend (VPC-only on a strict cell).
  # ECK names the Kibana HTTP service <kibana_name>-kb-http:5601.
  kibana_name      = "pavo-kibana"
  kibana_host      = "kibana.${var.customer_name}.${var.base_domain}"
  es_storage_class = "pavo-es-cmk-${var.instance_id}"
  es_storage_gb    = 50

  es_snapshot_role_arn  = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${local.es_snapshot_role_name}"
  es_snapshot_role_name = substr("pavo-es-snapshots-${var.instance_id}", 0, 64)

  # Three least-privilege fileRealm users (roles defined in es_roles below).
  es_file_realm_users = {
    "es-app-user"       = { generator = "es-app-pw", username = "pavo_app", role = "pavo_app_runtime" }
    "es-bootstrap-user" = { generator = "es-bootstrap-pw", username = "pavo_bootstrap", role = "pavo_es_bootstrap" }
    "es-exporter-user"  = { generator = "es-exporter-pw", username = "pavo_exporter", role = "pavo_es_exporter" }
  }
  es_users = local.es_self_hosted ? local.es_file_realm_users : {}
}

# Fail-fast: ECK must exist on the cell (published by pavo-bootstrap-aws). The
# tolerant lookup that backs local.eck_ready_present, and every other
# cell -> instance gate, lives in cell_gates.tf. The precondition on
# kubectl_manifest.elasticsearch below turns it into an actionable message.

# -----------------------------------------------------------------------------
# CMK gp3 StorageClass — EBS at rest under the customer CMK (INV-2)
# -----------------------------------------------------------------------------
resource "kubernetes_storage_class_v1" "es_cmk" {
  count = local.es_count

  metadata { name = local.es_storage_class }

  storage_provisioner    = "ebs.csi.aws.com"
  reclaim_policy         = "Delete"
  volume_binding_mode    = "WaitForFirstConsumer"
  allow_volume_expansion = true

  parameters = {
    type      = "gp3"
    encrypted = "true"
    kmsKeyId  = var.cell_kms_key_arn
  }
}

# -----------------------------------------------------------------------------
# fileRealm credentials — ESO Password generators + ExternalSecrets (INV-4/5)
# -----------------------------------------------------------------------------
# Passwords are generated in-cluster by ESO and never enter Terraform state.
# refreshInterval: "0" = generate-once (proven stable across operator restart /
# TF re-apply / metadata update in the spike; only force-sync regenerates — so
# never force-sync these, and ignore_changes guards against drift-rotation).
resource "kubectl_manifest" "es_password_generator" {
  for_each = local.es_users

  yaml_body = yamlencode({
    apiVersion = "generators.external-secrets.io/v1alpha1"
    kind       = "Password"
    metadata = {
      name      = each.value.generator
      namespace = local.es_namespace
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

  # Namespaced object — first-time self_hosted applies can otherwise race the
  # namespace and fail with namespace-not-found (same pattern as the SA/NetworkPolicy).
  depends_on = [kubectl_manifest.instance_namespace]
}

resource "kubectl_manifest" "es_user_external_secret" {
  for_each = local.es_users

  yaml_body = yamlencode({
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ExternalSecret"
    metadata = {
      name      = each.key
      namespace = local.es_namespace
    }
    spec = {
      refreshInterval = "0"
      target = {
        name           = each.key
        creationPolicy = "Owner"
        template = {
          type = "kubernetes.io/basic-auth"
          data = {
            username = each.value.username
            password = "{{ .password }}"
            roles    = each.value.role
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
  # Block Terraform until ESO has materialized the target secret, so ECK never
  # reconciles the fileRealm before the credential exists.
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
    kubectl_manifest.es_password_generator,
  ]
}

# Role definitions (native ES roles.yml). No secret material — safe in state.
resource "kubernetes_secret_v1" "es_roles" {
  count = local.es_count

  metadata {
    name      = "es-app-roles"
    namespace = local.es_namespace
  }

  data = {
    "roles.yml" = yamlencode({
      # App pods: read/write + self-install their own index templates. No `all`,
      # no manage/delete, no cluster admin.
      pavo_app_runtime = {
        cluster = ["monitor", "manage_index_templates"]
        indices = [{
          names      = ["*"]
          privileges = ["read", "write", "create_index", "view_index_metadata"]
        }]
      }
      # One-shot bootstrap Job (C3): snapshot repo + SLM. Granular, no broad manage.
      pavo_es_bootstrap = {
        cluster = ["monitor", "manage_slm", "cluster:admin/repository/*", "cluster:admin/snapshot/*"]
      }
      # Exporter: monitor-only, never the app write credential.
      pavo_es_exporter = {
        cluster = ["monitor"]
        indices = [{
          names      = ["*"]
          privileges = ["monitor", "view_index_metadata"]
        }]
      }
    })
  }

  # Namespaced object — order after the namespace to avoid a first-apply race.
  depends_on = [kubectl_manifest.instance_namespace]
}

# -----------------------------------------------------------------------------
# Snapshot pod identity — IRSA role + ServiceAccount (INV-1/4)
# -----------------------------------------------------------------------------
# Trust is pinned to the single ES ServiceAccount (NOT the namespace-wide app
# role), so only the ES pod — not every app pod — can assume it. The S3 + KMS
# permissions and the snapshot bucket/Job are added in C3.
data "aws_iam_policy_document" "es_snapshots_assume" {
  count = local.es_count

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    principals {
      type        = "Federated"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/${var.eks_oidc_provider}"]
    }
    condition {
      test     = "StringEquals"
      variable = "${var.eks_oidc_provider}:sub"
      values   = ["system:serviceaccount:${var.instance_id}:pavo-es"]
    }
    condition {
      test     = "StringEquals"
      variable = "${var.eks_oidc_provider}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "es_snapshots" {
  count = local.es_count

  name                 = local.es_snapshot_role_name
  assume_role_policy   = data.aws_iam_policy_document.es_snapshots_assume[0].json
  permissions_boundary = data.aws_ssm_parameter.permission_boundary_arn.value

  tags = { Name = local.es_snapshot_role_name }
}

resource "kubernetes_service_account_v1" "pavo_es" {
  count = local.es_count

  metadata {
    name      = "pavo-es"
    namespace = local.es_namespace
    annotations = {
      "eks.amazonaws.com/role-arn" = aws_iam_role.es_snapshots[0].arn
    }
  }

  depends_on = [kubectl_manifest.instance_namespace]
}

# -----------------------------------------------------------------------------
# Elasticsearch CR — single node, 0 replicas, ClusterIP-only (INV-1/3/6/9)
# -----------------------------------------------------------------------------
resource "kubectl_manifest" "elasticsearch" {
  count = local.es_count

  yaml_body = yamlencode({
    apiVersion = "elasticsearch.k8s.elastic.co/v1"
    kind       = "Elasticsearch"
    metadata = {
      name      = local.es_name
      namespace = local.es_namespace
    }
    spec = {
      version = local.es_version
      auth = {
        fileRealm = [for name in keys(local.es_file_realm_users) : { secretName = name }]
        roles     = [{ secretName = "es-app-roles" }]
      }
      http = {
        # ClusterIP only — never a public LB/Ingress (INV-1 residency).
        service = { spec = { type = "ClusterIP" } }
      }
      nodeSets = [{
        name  = "default"
        count = 1
        podTemplate = {
          spec = {
            serviceAccountName           = "pavo-es"
            automountServiceAccountToken = true
            containers = [{
              name = "elasticsearch"
              # Guaranteed QoS (requests==limits); ECK auto-sizes heap <=50% RAM.
              resources = {
                requests = { memory = "2Gi", cpu = "1" }
                limits   = { memory = "2Gi", cpu = "1" }
              }
              # IRSA web-identity token for the S3 repository plugin (snapshots).
              env = [
                { name = "AWS_ROLE_ARN", value = local.es_snapshot_role_arn },
                { name = "AWS_WEB_IDENTITY_TOKEN_FILE", value = "/usr/share/elasticsearch/config/repository-s3/aws-web-identity-token-file" },
              ]
              volumeMounts = [{
                name      = "aws-iam-token"
                mountPath = "/usr/share/elasticsearch/config/repository-s3"
                readOnly  = true
              }]
            }]
            volumes = [{
              name = "aws-iam-token"
              projected = {
                sources = [{
                  serviceAccountToken = {
                    audience          = "sts.amazonaws.com"
                    expirationSeconds = 86400
                    path              = "aws-web-identity-token-file"
                  }
                }]
              }
            }]
          }
        }
        volumeClaimTemplates = [{
          metadata = { name = "elasticsearch-data" }
          spec = {
            accessModes      = ["ReadWriteOnce"]
            storageClassName = local.es_storage_class
            resources        = { requests = { storage = "${local.es_storage_gb}Gi" } }
          }
        }]
      }]
    }
  })

  server_side_apply = true
  force_conflicts   = true

  lifecycle {
    # Replaces the old `depends_on = [data.aws_ssm_parameter.eck_ready, ...]`
    # edge: referencing local.eck_ready_present already creates the dependency
    # on the SSM read, so an explicit depends_on would be redundant. Do not
    # re-add it.
    #
    # This also fires on an ALREADY-CREATED instance whose condition later goes
    # false, which is the enable_eck true->false hazard documented in
    # pavo-bootstrap-aws/README.md. Verified against a live cell.
    precondition {
      condition     = local.eck_ready_present
      error_message = <<-EOT
        Self-hosted Elasticsearch requires ECK on cell ${var.eks_cluster_name},
        but ${local.eck_ready_name} does not exist.

        FIX: re-run pavo-bootstrap-aws for this cell with enable_eck = true,
        then retry this deployment. The cell publishes that parameter only after
        the ECK operator is actually running.
      EOT
    }
  }

  depends_on = [
    kubernetes_storage_class_v1.es_cmk,
    kubernetes_secret_v1.es_roles,
    kubernetes_service_account_v1.pavo_es,
    kubectl_manifest.es_user_external_secret,
  ]
}

# -----------------------------------------------------------------------------
# NetworkPolicy — ES-scoped INGRESS only, no namespace-wide default-deny (INV-1b)
# -----------------------------------------------------------------------------
# podSelector-scoped so it isolates ES without touching the ~18-pod app stack.
# INV-1b still holds for the default (standard) posture. network_posture=strict
# adds a namespace-wide EGRESS policy in network_policies.tf; the two do not
# interact, because NetworkPolicies of different policyTypes are evaluated
# independently and same-type rules union rather than intersect.
# Effective only once CNI enforcement is enabled on the cell (Omnistrate addon);
# harmless before then. Allows 9200 from es-client-labeled pods + the ECK
# operator namespace (else reconciliation breaks).
resource "kubectl_manifest" "es_network_policy" {
  count = local.es_count

  yaml_body = yamlencode({
    apiVersion = "networking.k8s.io/v1"
    kind       = "NetworkPolicy"
    metadata = {
      name      = "pavo-es-allow"
      namespace = local.es_namespace
    }
    spec = {
      podSelector = {
        matchLabels = { "elasticsearch.k8s.elastic.co/cluster-name" = local.es_name }
      }
      policyTypes = ["Ingress"]
      ingress = [
        {
          # app clients (labeled) + the ECK operator namespace
          from = [
            { podSelector = { matchLabels = { "pavo.ai/es-client" = "true" } } },
            { namespaceSelector = { matchLabels = { "kubernetes.io/metadata.name" = "elastic-system" } } },
          ]
          ports = [{ protocol = "TCP", port = 9200 }]
        },
        {
          # transport (9300) restricted to ES pods only (single node => no peers)
          from  = [{ podSelector = { matchLabels = { "elasticsearch.k8s.elastic.co/cluster-name" = local.es_name } } }]
          ports = [{ protocol = "TCP", port = 9300 }]
        },
      ]
    }
  })

  server_side_apply = true
  force_conflicts   = true

  depends_on = [kubectl_manifest.instance_namespace]
}

# -----------------------------------------------------------------------------
# Kibana (ECK) — the ES UI (index/doc inspection, Dev Tools). Per-instance,
# same es_mode=self_hosted gate as ES. ECK auto-provisions the kibana_system
# user + wiring from elasticsearchRef; operators log in with an ES native/file
# realm user (e.g. the elastic superuser). Residency: ES stays ClusterIP-only;
# Kibana's ONLY public path is the pavo-nginx Ingress below, so on a strict cell
# (network_posture=strict) it is VPC-only, same as Grafana.
# -----------------------------------------------------------------------------
resource "kubectl_manifest" "kibana" {
  count = local.es_count

  yaml_body = yamlencode({
    apiVersion = "kibana.k8s.elastic.co/v1"
    kind       = "Kibana"
    metadata = {
      name      = local.kibana_name
      namespace = local.es_namespace
    }
    spec = {
      version          = local.es_version
      count            = 1
      elasticsearchRef = { name = local.es_name }
      http = {
        # Serve plain HTTP in-cluster; nginx terminates the public Let's Encrypt
        # cert at the edge (same pattern as Zitadel/Grafana). ClusterIP only.
        tls     = { selfSignedCertificate = { disabled = true } }
        service = { spec = { type = "ClusterIP" } }
      }
      config = {
        "server.publicBaseUrl" = "https://${local.kibana_host}"
      }
      podTemplate = {
        metadata = {
          # Pass the ES NetworkPolicy — :9200 admits pavo.ai/es-client=true pods.
          labels = { "pavo.ai/es-client" = "true" }
        }
        spec = {
          containers = [{
            name = "kibana"
            resources = {
              requests = { memory = "1Gi", cpu = "500m" }
              limits   = { memory = "1Gi", cpu = "1" }
            }
          }]
        }
      }
    }
  })

  server_side_apply = true
  force_conflicts   = true

  depends_on = [kubectl_manifest.elasticsearch]
}

# Public browser path for Kibana — pavo-nginx + Let's Encrypt (both cell-scoped,
# from pavo-bootstrap-aws), at kibana.<customer_name>.<base_domain>. Kibana
# serves HTTP (TLS disabled above), so the backend is plain HTTP (no re-encrypt).
# Applied via kubectl_manifest (server-side apply) like every other resource in
# this file, so it ADOPTS a pre-existing "kibana" Ingress (e.g. one applied by
# hand during testing) instead of failing the apply with "already exists".
resource "kubectl_manifest" "kibana_ingress" {
  count = local.es_count

  yaml_body = yamlencode({
    apiVersion = "networking.k8s.io/v1"
    kind       = "Ingress"
    metadata = {
      name      = "kibana"
      namespace = local.es_namespace
      annotations = {
        "cert-manager.io/cluster-issuer" = "pavo-letsencrypt-prod"
      }
    }
    spec = {
      ingressClassName = "pavo-nginx"
      tls = [{
        hosts      = [local.kibana_host]
        secretName = "kibana-tls"
      }]
      rules = [{
        host = local.kibana_host
        http = {
          paths = [{
            path     = "/"
            pathType = "Prefix"
            backend = {
              service = {
                name = "${local.kibana_name}-kb-http"
                port = { number = 5601 }
              }
            }
          }]
        }
      }]
    }
  })

  server_side_apply = true
  force_conflicts   = true

  depends_on = [kubectl_manifest.kibana]
}

# -----------------------------------------------------------------------------
# elasticsearch_exporter — monitor-only metrics for platform Prometheus
# -----------------------------------------------------------------------------
resource "kubectl_manifest" "es_exporter" {
  count = local.es_count

  yaml_body = yamlencode({
    apiVersion = "apps/v1"
    kind       = "Deployment"
    metadata = {
      name      = "pavo-es-exporter"
      namespace = local.es_namespace
      labels    = { "pavo.ai/es-client" = "true" }
    }
    spec = {
      replicas = 1
      selector = { matchLabels = { app = "pavo-es-exporter" } }
      template = {
        metadata = {
          labels = { app = "pavo-es-exporter", "pavo.ai/es-client" = "true" }
          annotations = {
            "prometheus.io/scrape" = "true"
            "prometheus.io/port"   = "9114"
          }
        }
        spec = {
          containers = [{
            name  = "exporter"
            image = "quay.io/prometheuscommunity/elasticsearch-exporter:v1.7.0"
            args = [
              "--es.uri=https://${local.es_name}-es-http.${local.es_namespace}.svc:9200",
              # TLS verification is ON by default (skip-verify defaults to false) and
              # anchored on the ECK CA below. Do NOT pass --es.ssl-skip-verify=false:
              # it's a boolean toggle in exporter v1.7.0 and the "=false" form is
              # rejected ("unexpected false"), crashlooping the exporter.
              "--es.ca=/etc/es-certs/ca.crt",
            ]
            env = [
              { name = "ES_USERNAME", valueFrom = { secretKeyRef = { name = "es-exporter-user", key = "username" } } },
              { name = "ES_PASSWORD", valueFrom = { secretKeyRef = { name = "es-exporter-user", key = "password" } } },
            ]
            ports = [{ containerPort = 9114 }]
            volumeMounts = [{
              name      = "es-ca"
              mountPath = "/etc/es-certs"
              readOnly  = true
            }]
          }]
          volumes = [{
            name   = "es-ca"
            secret = { secretName = "${local.es_name}-es-http-certs-public" }
          }]
        }
      }
    }
  })

  server_side_apply = true
  force_conflicts   = true

  depends_on = [kubectl_manifest.elasticsearch]
}

# Stable Service in front of the ES exporter Deployment so Prometheus can scrape
# it via an explicit static target (DNS: pavo-es-exporter.<ns>.svc:9114) instead
# of broad annotation-based pod discovery — the strict-cell metric-hygiene
# invariant. Gated on local.es_count, so it appears/disappears with the exporter
# (es_mode=self_hosted). Selector is copied verbatim from the exporter
# Deployment's pod labels; a mismatch would yield zero endpoints.
resource "kubectl_manifest" "es_exporter_service" {
  count = local.es_count

  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "Service"
    metadata = {
      name      = "pavo-es-exporter"
      namespace = local.es_namespace
      labels    = { app = "pavo-es-exporter" }
    }
    spec = {
      selector = { app = "pavo-es-exporter" }
      ports = [{
        name       = "metrics"
        port       = 9114
        targetPort = 9114
      }]
    }
  })

  server_side_apply = true
  force_conflicts   = true

  depends_on = [kubectl_manifest.es_exporter]
}
