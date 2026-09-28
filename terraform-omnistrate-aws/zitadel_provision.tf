# =============================================================================
# Step 5 — Provision Job: configure the customer's in-VPC Zitadel
# =============================================================================
# Runs the baked zitadel-provisioner image (terraform + pavo-customer-bootstrap)
# against the internal Zitadel svc using the FirstInstance machine KEY, with
# state in a per-instance customer S3 bucket. A handoff container then turns the
# module outputs into the K8s objects api-gateway + frontend consume. All
# count-gated on local.zitadel_count (cloud path untouched).

# -----------------------------------------------------------------------------
# Inputs — the identity config the in-VPC pavo-customer-bootstrap needs.
# (Cloud mode gets these already-provisioned via the zitadel_* pass-through
# vars; self_hosted mode provisions them here, so it needs the raw inputs.)
# -----------------------------------------------------------------------------
variable "zitadel_provisioner_image" {
  description = "Digest-pinned zitadel-provisioner image (ghcr.io/pavoai/zitadel-provisioner@sha256:...). Built + cosign-signed + attested (SBOM/vuln/OpenVEX) by the zitadel-provisioner-omnistrate Cloud Build trigger; pin the resulting digest here. See zitadel-provisioner/SIGNING.md."
  type        = string
  # Digest of the signed zitadel-provisioner image (includes the internal-transport
  # fix). cosign-signed by cloud-build-zitadel-prov@onboarding-455713, with
  # SBOM/vuln/OpenVEX attestations attached to the digest; OS scan clean.
  default = "ghcr.io/pavoai/zitadel-provisioner@sha256:f953dbbc7f98262a9140a1ad0982e2b4d59b75430a518c369ecdae895acb24c0"
}

variable "primary_external_identity_provider_automation_enabled" {
  description = "self_hosted only: provision the customer IdP + IdP-only login policy (module input). Cloud mode ignores this."
  type        = bool
  default     = false
}

variable "primary_external_identity_provider_client_id" {
  description = "self_hosted only: customer IdP OAuth/OIDC client ID (module input primary_external_identity_provider_client_id)."
  type        = string
  sensitive   = true
  default     = ""
}

variable "primary_external_identity_provider_client_secret" {
  description = "self_hosted only: customer IdP OAuth/OIDC client secret (module input primary_external_identity_provider_client_secret)."
  type        = string
  sensitive   = true
  default     = ""
}

variable "primary_external_identity_provider_oidc_issuer" {
  description = "self_hosted only: customer IdP OIDC issuer URL (module input). Mutually exclusive with the SAML metadata URL."
  type        = string
  default     = ""
}

variable "primary_external_identity_provider_saml_metadata_url" {
  description = "self_hosted only: customer IdP SAML metadata URL (module input). Mutually exclusive with the OIDC issuer."
  type        = string
  default     = ""
}

locals {
  # instance_id is globally unique + short, so this stays well under S3's 63-char
  # limit regardless of customer_name length (which is unbounded here).
  zitadel_state_bucket    = "pavo-zitadel-state-${var.instance_id}"
  zitadel_provision_sa    = "zitadel-provisioner"
  zitadel_backend_secret  = "zitadel-backend-secret"
  zitadel_frontend_config = "zitadel-frontend-public-config"
  zitadel_internal_url    = "https://zitadel.${local.zitadel_namespace}.svc:8080"

  # Re-run trigger: any change to the identity inputs OR the provisioner image
  # (which bakes all module logic) → new hash → new Job. nonsensitive() un-taints
  # the digest so it can be a resource name (the hash never leaks the inputs).
  zitadel_provision_hash = substr(nonsensitive(sha1(join("|", [
    var.customer_name,
    var.base_domain,
    local.zitadel_auth_host,
    var.zitadel_provisioner_image,
    var.primary_external_identity_provider_automation_enabled ? "1" : "0",
    var.primary_external_identity_provider_type,
    var.primary_external_identity_provider_label,
    var.primary_external_identity_provider_prompt,
    var.primary_external_identity_provider_client_id,
    var.primary_external_identity_provider_client_secret,
    var.primary_external_identity_provider_oidc_issuer,
    var.primary_external_identity_provider_saml_metadata_url,
  ]))), 0, 10)
}

# -----------------------------------------------------------------------------
# Per-instance S3 state bucket — SSE-KMS under the customer CMK (pavo-* per the
# instance IAM boundary). Versioned so a bad apply is recoverable.
# -----------------------------------------------------------------------------
resource "aws_s3_bucket" "zitadel_state" {
  count         = local.zitadel_count
  bucket        = local.zitadel_state_bucket
  force_destroy = var.force_destroy_buckets
  tags          = { Name = local.zitadel_state_bucket }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "zitadel_state" {
  count  = local.zitadel_count
  bucket = aws_s3_bucket.zitadel_state[0].id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = var.cell_kms_key_arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "zitadel_state" {
  count                   = local.zitadel_count
  bucket                  = aws_s3_bucket.zitadel_state[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "zitadel_state" {
  count  = local.zitadel_count
  bucket = aws_s3_bucket.zitadel_state[0].id
  versioning_configuration { status = "Enabled" }
}

# -----------------------------------------------------------------------------
# IRSA — the Provision Job pod reads/writes only its own state bucket + the CMK.
# -----------------------------------------------------------------------------
data "aws_iam_policy_document" "zitadel_provision_assume" {
  count = local.zitadel_count
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
      values   = ["system:serviceaccount:${var.instance_id}:${local.zitadel_provision_sa}"]
    }
    condition {
      test     = "StringEquals"
      variable = "${var.eks_oidc_provider}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "zitadel_provision" {
  count                = local.zitadel_count
  name                 = substr("pavo-zitadel-prov-${var.instance_id}", 0, 64)
  assume_role_policy   = data.aws_iam_policy_document.zitadel_provision_assume[0].json
  permissions_boundary = data.aws_ssm_parameter.permission_boundary_arn.value
  tags                 = { Name = "pavo-zitadel-prov-${var.instance_id}" }
}

data "aws_iam_policy_document" "zitadel_provision" {
  count = local.zitadel_count
  statement {
    sid     = "StateBucket"
    effect  = "Allow"
    actions = ["s3:ListBucket", "s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = [
      aws_s3_bucket.zitadel_state[0].arn,
      "${aws_s3_bucket.zitadel_state[0].arn}/*",
    ]
  }
  statement {
    sid       = "StateBucketCMK"
    effect    = "Allow"
    actions   = ["kms:Encrypt", "kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"]
    resources = [data.aws_kms_key.cell_cmk.arn]
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["s3.${var.aws_region}.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "zitadel_provision" {
  count  = local.zitadel_count
  name   = "state-access"
  role   = aws_iam_role.zitadel_provision[0].id
  policy = data.aws_iam_policy_document.zitadel_provision[0].json
}

resource "kubernetes_service_account_v1" "zitadel_provision" {
  count = local.zitadel_count
  metadata {
    name      = local.zitadel_provision_sa
    namespace = local.zitadel_namespace
    annotations = {
      "eks.amazonaws.com/role-arn" = aws_iam_role.zitadel_provision[0].arn
    }
  }
  depends_on = [kubectl_manifest.instance_namespace]
}

# The provision SA writes the two handoff objects (and reads the machine key).
resource "kubernetes_role_v1" "zitadel_provision" {
  count = local.zitadel_count
  metadata {
    name      = local.zitadel_provision_sa
    namespace = local.zitadel_namespace
  }
  rule {
    api_groups = [""]
    resources  = ["secrets", "configmaps"]
    verbs      = ["get", "create", "patch"]
  }
}

resource "kubernetes_role_binding_v1" "zitadel_provision" {
  count = local.zitadel_count
  metadata {
    name      = local.zitadel_provision_sa
    namespace = local.zitadel_namespace
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role_v1.zitadel_provision[0].metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.zitadel_provision[0].metadata[0].name
    namespace = local.zitadel_namespace
  }
}

# -----------------------------------------------------------------------------
# The customer IdP client secret, kept in a K8s Secret so it is referenced (not
# inlined) into the Provision Job env — off the Pod spec / etcd pod object.
# (The value is already a sensitive TF var, so this adds no new state exposure.)
resource "kubernetes_secret_v1" "zitadel_idp_client_secret" {
  count = local.zitadel_count
  metadata {
    name      = "zitadel-idp-client-secret"
    namespace = local.zitadel_namespace
  }
  data = {
    client_secret = var.primary_external_identity_provider_client_secret
  }
}

# Provision Job — provisioner (Terraform) initContainer, then the handoff
# container that materializes the K8s objects api-gateway + frontend consume.
# -----------------------------------------------------------------------------
resource "kubernetes_job_v1" "zitadel_provision" {
  count = local.zitadel_count

  depends_on = [
    kubernetes_deployment_v1.zitadel, # Zitadel is serving
    kubernetes_job_v1.zitadel_setup,  # machine key exists
    kubernetes_role_binding_v1.zitadel_provision,
    aws_iam_role_policy.zitadel_provision,
    aws_s3_bucket_versioning.zitadel_state,
    kubernetes_secret_v1.zitadel_idp_client_secret,
    # Sigstore signaturePullSecret must exist before this Job's (signed,
    # enforce-gated) provisioner image is admitted — else the webhook 401s on
    # the private-ghcr signature fetch and denies the pod.
    kubernetes_secret_v1.ghcr_signature_pull,
  ]

  metadata {
    name      = "pavo-zitadel-provision-${local.zitadel_provision_hash}"
    namespace = local.zitadel_namespace
  }

  spec {
    backoff_limit              = 2
    active_deadline_seconds    = 900
    ttl_seconds_after_finished = 600

    template {
      metadata {}
      spec {
        enable_service_links = false
        node_selector        = local.zitadel_node_selector
        service_account_name = kubernetes_service_account_v1.zitadel_provision[0].metadata[0].name
        restart_policy       = "Never"
        # Public-issuer / internal-transport split. The zitadel provider derives
        # BOTH the dial address AND the expected issuer from `domain` (the public
        # auth host), and can't send a Host header that differs from the address
        # it dials. So we make the public host resolve to the in-VPC Zitadel
        # ClusterIP right here in the pod: the provider connects to
        # https://<public-host>:8080, which routes internally (reachable), and
        # Zitadel — keyed on that Host — returns the matching public issuer. Done
        # at pod level because the provisioner runs as uid 1000 and can't edit
        # /etc/hosts itself.
        host_aliases {
          ip        = kubernetes_service_v1.zitadel[0].spec[0].cluster_ip
          hostnames = [local.zitadel_auth_host]
        }
        # The provisioner init image is a PRIVATE ghcr.io/pavoai repo, so kubelet
        # needs a pull credential (separate from the Sigstore signaturePullSecret
        # used for verification — that one is on the CIP). Reuse the same
        # per-namespace secret pavoInfra materializes.
        image_pull_secrets {
          name = "pavo-ghcr-signature-pull"
        }
        # The provisioner image runs as uid 1000; fsGroup makes the /handoff
        # emptyDir + mounted secrets writable/readable by that GID. (No pod-wide
        # run_as_non_root — the handoff container uses a root-based kubectl image.)
        security_context {
          fs_group = 1000
        }

        # --- provision: terraform apply of pavo-customer-bootstrap ------------
        init_container {
          name  = "provision"
          image = var.zitadel_provisioner_image

          # Trust Zitadel's in-VPC serving cert. Zitadel serves a cert-manager
          # self-signed cert (Issuer zitadel-selfsigned); the provider's
          # JWT-profile token exchange runs over an oauth2 http.Client that
          # verifies against Go's SystemCertPool, and `insecure_skip_verify_tls`
          # only covers the gRPC API dial — NOT that token call. So we build a
          # combined bundle (system CAs + the self-signed CA mounted at
          # /zitadel-ca) and point every Go TLS client at it via SSL_CERT_FILE.
          # We wrap the baked ENTRYPOINT (provision.sh) so the bundle exists
          # before OpenTofu runs. The cert's SAN covers the public auth host, so
          # full verification passes and TF_VAR_zitadel_insecure flips to false.
          command = ["/bin/sh", "-c"]
          args = [
            "cat /etc/ssl/certs/ca-certificates.crt /zitadel-ca/ca.crt > /tmp/ca-bundle.pem && exec /usr/local/bin/provision.sh",
          ]
          env {
            name  = "SSL_CERT_FILE"
            value = "/tmp/ca-bundle.pem"
          }

          env {
            name  = "BACKEND_BUCKET"
            value = aws_s3_bucket.zitadel_state[0].id
          }
          env {
            name  = "BACKEND_KEY"
            value = "zitadel/terraform.tfstate"
          }
          env {
            name  = "BACKEND_REGION"
            value = var.aws_region
          }
          env {
            name  = "ZITADEL_INTERNAL_URL"
            value = local.zitadel_internal_url
          }
          env {
            name  = "EXPECTED_ISSUER"
            value = "https://${local.zitadel_auth_host}"
          }
          env {
            name  = "HANDOFF_DIR"
            value = "/handoff"
          }
          # Provider endpoint (internal HTTPS + machine key; F9/F10).
          env {
            name  = "TF_VAR_zitadel_domain"
            value = local.zitadel_auth_host
          }
          env {
            name  = "TF_VAR_zitadel_port"
            value = "8080"
          }
          # false: full TLS verification against the mounted self-signed CA (see
          # the SSL_CERT_FILE bundle above). Previously "true" (skip-verify),
          # which never took effect on the provider's JWT-profile token client
          # and produced "tls: bad certificate" against the in-VPC Zitadel.
          env {
            name  = "TF_VAR_zitadel_insecure"
            value = "false"
          }
          env {
            name  = "TF_VAR_zitadel_jwt_profile_file"
            value = "/keys/sa.json"
          }
          # Identity inputs.
          env {
            name  = "TF_VAR_customer_name"
            value = var.customer_name
          }
          env {
            name  = "TF_VAR_base_domain"
            value = var.base_domain
          }
          env {
            name  = "TF_VAR_primary_external_identity_provider_automation_enabled"
            value = var.primary_external_identity_provider_automation_enabled ? "true" : "false"
          }
          env {
            name  = "TF_VAR_primary_external_identity_provider_type"
            value = var.primary_external_identity_provider_type
          }
          env {
            name  = "TF_VAR_primary_external_identity_provider_label"
            value = var.primary_external_identity_provider_label
          }
          env {
            name  = "TF_VAR_primary_external_identity_provider_prompt"
            value = var.primary_external_identity_provider_prompt
          }
          env {
            name  = "TF_VAR_primary_external_identity_provider_client_id"
            value = var.primary_external_identity_provider_client_id
          }
          # Sourced from a K8s Secret (not inline value) so the IdP client secret
          # does not land in the Pod spec / etcd pod object (INV-7).
          env {
            name = "TF_VAR_primary_external_identity_provider_client_secret"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.zitadel_idp_client_secret[0].metadata[0].name
                key  = "client_secret"
              }
            }
          }
          env {
            name  = "TF_VAR_primary_external_identity_provider_oidc_issuer"
            value = var.primary_external_identity_provider_oidc_issuer
          }
          env {
            name  = "TF_VAR_primary_external_identity_provider_saml_metadata_url"
            value = var.primary_external_identity_provider_saml_metadata_url
          }

          # OpenTofu writes its data dir (.terraform: provider plugins, backend
          # metadata, transient lock state) into the working directory. The
          # image WORKDIR is root-owned and this container runs as uid 1000, so
          # point TF_DATA_DIR at a writable emptyDir to avoid "permission denied"
          # on `.terraform/terraform.tfstate` during backend init.
          env {
            name  = "TF_DATA_DIR"
            value = "/tf-data"
          }

          volume_mount {
            name       = "tf-data"
            mount_path = "/tf-data"
          }
          volume_mount {
            name       = "machine-key"
            mount_path = "/keys"
            read_only  = true
          }
          volume_mount {
            name       = "handoff"
            mount_path = "/handoff"
          }
          # Zitadel's self-signed serving CA — concatenated into the SSL_CERT_FILE
          # bundle at container start (see command/args above).
          volume_mount {
            name       = "zitadel-ca"
            mount_path = "/zitadel-ca"
            read_only  = true
          }
        }

        # --- handoff: module outputs → K8s objects (no client secret to FE) ---
        container {
          name    = "handoff"
          image   = local.zitadel_kubectl_image
          command = ["/bin/bash", "-c"]
          args = [<<-EOT
            set -euo pipefail
            OUT=/handoff/outputs.json
            get() { jq -r ".$1.value // \"\"" "$OUT"; }

            cid="$(get zitadel_oidc_client_id)"
            csec="$(get zitadel_oidc_client_secret)"
            org="$(get zitadel_org_id)"
            idp="$(get zitadel_idp_id)"
            dom="$(get zitadel_org_primary_domain)"
            iss="$(get zitadel_issuer)"
            en="$(get primary_external_identity_provider_enabled)"
            ty="$(get primary_external_identity_provider_type)"
            la="$(get primary_external_identity_provider_label)"
            pr="$(get primary_external_identity_provider_prompt)"

            # Numeric Zitadel ids exceed JS 2^53, so the frontend consumes them
            # base64-encoded (matches the central pass-through contract).
            b64() { printf '%s' "$1" | base64 | tr -d '\n'; }

            # api-gateway secret — client secret + org/idp live ONLY here (INV-7).
            # AGENTS.md exception: no identity LOGIC lives here — the handoff only
            # materializes pavo-customer-bootstrap outputs ($cid, $csec, $iss, …
            # via `get zitadel_*`) into the K8s secret its in-namespace consumers
            # read, with base64encode as the one allowed transform. It must run in
            # this module because bootstrap executes inside the provisioner and has
            # no kubectl access to the outer instance namespace.
            # ZITADEL_DOMAIN + ZITADEL_CLIENT_ID_BASE64 are also written here so
            # they OVERRIDE the chart's central-defaulted / stale-result-param
            # values (envFrom lists this secret AFTER the chart ConfigMap, so its
            # keys win). Without this the api-gateway does its OIDC code→token
            # exchange against the central broker (auth.pavoai.com) with a stale
            # client id — the self_hosted app lives only in the in-VPC Zitadel, so
            # the exchange fails "invalid_client: no active client not found".
            # ZITADEL_DOMAIN=the self_hosted issuer (auth.<customer>.pavoai.dev,
            # resolvable in-pod to the ingress); CLIENT_ID_BASE64=this instance's
            # freshly-provisioned OIDC client (api-gateway prefers the base64 var).
            kubectl -n "$NS" create secret generic "$BACKEND_SECRET" \
              --from-literal=ZITADEL_CLIENT_ID="$cid" \
              --from-literal=ZITADEL_CLIENT_ID_BASE64="$(b64 "$cid")" \
              --from-literal=ZITADEL_CLIENT_SECRET="$csec" \
              --from-literal=ZITADEL_DOMAIN="$iss" \
              --from-literal=ZITADEL_ORG_ID="$org" \
              --from-literal=ZITADEL_IDP_ID="$idp" \
              --dry-run=client -o yaml | kubectl apply -f -

            # frontend public config — NO client secret; keys/ids base64 to match
            # start.sh's VITE_* contract (VITE_ZITADEL_AUTHORITY + redirect URI
            # are Terraform-known and injected via Helm, not here).
            kubectl -n "$NS" create configmap "$FRONTEND_CONFIG" \
              --from-literal=VITE_ZITADEL_CLIENT_ID_BASE64="$(b64 "$cid")" \
              --from-literal=VITE_ZITADEL_ORGANIZATION_ID_BASE64="$(b64 "$org")" \
              --from-literal=VITE_ZITADEL_IDP_ID_BASE64="$(b64 "$idp")" \
              --from-literal=VITE_ZITADEL_PRIMARY_DOMAIN="$dom" \
              --from-literal=VITE_PRIMARY_EXTERNAL_IDENTITY_PROVIDER_ENABLED="$en" \
              --from-literal=VITE_PRIMARY_EXTERNAL_IDENTITY_PROVIDER_TYPE="$ty" \
              --from-literal=VITE_PRIMARY_EXTERNAL_IDENTITY_PROVIDER_LABEL="$la" \
              --from-literal=VITE_PRIMARY_EXTERNAL_IDENTITY_PROVIDER_PROMPT="$pr" \
              --dry-run=client -o yaml | kubectl apply -f -

            echo "handoff objects written: $BACKEND_SECRET (+secret) / $FRONTEND_CONFIG (public)"
          EOT
          ]
          env {
            name  = "NS"
            value = local.zitadel_namespace
          }
          env {
            name  = "BACKEND_SECRET"
            value = local.zitadel_backend_secret
          }
          env {
            name  = "FRONTEND_CONFIG"
            value = local.zitadel_frontend_config
          }
          volume_mount {
            name       = "handoff"
            mount_path = "/handoff"
            read_only  = true
          }
        }

        volume {
          name = "machine-key"
          secret {
            secret_name = local.zitadel_provisioner_secret
          }
        }
        # The cert-manager self-signed CA that signs Zitadel's internal serving
        # cert. Mounted read-only into the provision container so its Go TLS
        # clients (JWT-profile token exchange + gRPC API) trust the in-VPC
        # Zitadel endpoint. Produced by kubectl_manifest.zitadel_internal_cert
        # (zitadel_self_hosted.tf); present by the time this Job runs since it
        # depends_on the Zitadel deployment, which mounts the same secret.
        volume {
          name = "zitadel-ca"
          secret {
            secret_name = "zitadel-internal-tls"
            items {
              key  = "ca.crt"
              path = "ca.crt"
            }
          }
        }
        volume {
          name = "handoff"
          empty_dir {}
        }
        # Writable scratch for OpenTofu's TF_DATA_DIR (.terraform) — see the
        # provision init container.
        volume {
          name = "tf-data"
          empty_dir {}
        }
      }
    }
  }

  wait_for_completion = true
  timeouts {
    create = "20m"
    update = "20m"
  }
}
