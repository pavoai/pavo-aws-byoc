# =============================================================================
# Step 7 — Readiness gate (INV-10)
# =============================================================================
# The instance is not "ready" until: the identity config is applied (Provision
# Job succeeded — a depends_on), Zitadel serves the correct issuer over internal
# TLS, and both handoff objects exist. Blocks the apply on those. The public Let's
# Encrypt cert (browser-only path) is checked best-effort and does NOT block —
# it depends on external ACME/DNS/LE-rate-limits and isn't on the app OIDC path.
#
# The app / IdP / login-policy config assertions (Step 7 a/b/c) are guaranteed
# by the Provision Job's `terraform apply` succeeding, so they aren't re-checked
# here via the API (which would need JWT-profile signing in-Job). Step 7d ("no
# standing IAM_OWNER") does not apply: under the import-free model the per-
# instance provisioner is deliberately IAM_OWNER of ITS OWN instance's Zitadel
# only (not cross-tenant). Downgrading it to ORG_OWNER (the org-import model +
# IAM_OWNER revoke) is a documented prod-hardening follow-up.

# The readiness Job reuses the provisioner SA but needs to READ cert-manager
# Certificates too — extend that Role with a get on certificates.
resource "kubernetes_role_v1" "zitadel_readiness" {
  count = local.zitadel_count
  metadata {
    name      = "zitadel-readiness"
    namespace = local.zitadel_namespace
  }
  # Scoped to the exact objects the readiness Job reads (get-by-name).
  rule {
    api_groups     = [""]
    resources      = ["secrets", "configmaps"]
    resource_names = ["zitadel-backend-secret", "zitadel-frontend-public-config"]
    verbs          = ["get"]
  }
  rule {
    api_groups     = ["cert-manager.io"]
    resources      = ["certificates"]
    resource_names = ["zitadel-tls"]
    verbs          = ["get"]
  }
}

resource "kubernetes_role_binding_v1" "zitadel_readiness" {
  count = local.zitadel_count
  metadata {
    name      = "zitadel-readiness"
    namespace = local.zitadel_namespace
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role_v1.zitadel_readiness[0].metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.zitadel_provision[0].metadata[0].name
    namespace = local.zitadel_namespace
  }
}

resource "kubernetes_job_v1" "zitadel_readiness" {
  count = local.zitadel_count

  depends_on = [
    kubernetes_job_v1.zitadel_provision, # identity config applied + handoff written
    kubernetes_role_binding_v1.zitadel_readiness,
  ]

  metadata {
    name      = "pavo-zitadel-readiness-${local.zitadel_provision_hash}"
    namespace = local.zitadel_namespace
  }

  spec {
    backoff_limit              = 1
    active_deadline_seconds    = 900
    ttl_seconds_after_finished = 600

    template {
      metadata {}
      spec {
        enable_service_links = false
        node_selector        = local.zitadel_node_selector
        service_account_name = kubernetes_service_account_v1.zitadel_provision[0].metadata[0].name
        restart_policy       = "Never"

        container {
          name    = "readiness"
          image   = local.zitadel_kubectl_image
          command = ["/bin/bash", "-c"]
          args = [<<-EOT
            set -euo pipefail

            # 1. Zitadel serves the correct issuer over internal TLS (INV-4).
            #    -k: internal self-signed cert, skip-verify in-cluster.
            echo "asserting internal issuer ..."
            for i in $(seq 1 48); do
              iss="$(curl -fsk --connect-timeout 3 --max-time 8 -H "Host: $AUTH_HOST" "$INTERNAL_URL/.well-known/openid-configuration" 2>/dev/null | jq -r '.issuer' || true)"
              [ "$iss" = "https://$AUTH_HOST" ] && break
              [ "$i" = 48 ] && { echo "FATAL: issuer not ready (got '$iss')"; exit 1; }
              sleep 5
            done
            echo "issuer OK: https://$AUTH_HOST"

            # 2. Let's Encrypt cert for the public host — best-effort, NON-blocking.
            #    This cert fronts ONLY the public browser path. The api-gateway <->
            #    Zitadel OIDC path uses the internal svc (asserted in step 1) with
            #    the internal self-signed cert, so app correctness does not depend
            #    on it. LE issuance hinges on external ACME + public DNS + LE rate
            #    limits, so we must NOT couple the apply to it — we wait briefly,
            #    log the status, and continue; cert-manager keeps retrying issuance
            #    in the background until the browser path goes green.
            echo "checking Certificate zitadel-tls (best-effort) ..."
            ready=""
            for i in $(seq 1 24); do
              ready="$(kubectl -n "$NS" get certificate zitadel-tls -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
              [ "$ready" = "True" ] && break
              sleep 5
            done
            if [ "$ready" = "True" ]; then
              echo "public cert Ready"
            else
              echo "WARNING: public LE cert not Ready yet (status='$ready') — continuing; cert-manager will keep retrying. The internal OIDC path is unaffected." >&2
            fi

            # 3. Handoff objects exist (api-gateway + frontend can wire up).
            kubectl -n "$NS" get secret zitadel-backend-secret >/dev/null
            kubectl -n "$NS" get configmap zitadel-frontend-public-config >/dev/null
            echo "handoff objects present"

            echo "READY"
          EOT
          ]
          env {
            name  = "NS"
            value = local.zitadel_namespace
          }
          env {
            name  = "AUTH_HOST"
            value = local.zitadel_auth_host
          }
          env {
            name  = "INTERNAL_URL"
            value = local.zitadel_internal_url
          }
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
