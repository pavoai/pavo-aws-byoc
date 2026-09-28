# =============================================================================
# Observability convergence barrier (Phase 4)
# =============================================================================
# INVARIANT:
#   A newly created cell must not complete Phase 4 successfully unless the
#   minimum observability data path has converged at least once.
#
# This is a ONE-TIME CREATION ASSERTION, not a permanent health check. Terraform
# must not become an ongoing monitoring system: continuous health after creation
# belongs to Prometheus, Alertmanager and the workload-health rules in
# pavo-bootstrap-aws/observability/prometheus-values.yaml.tftpl.
#
# WHY THIS EXISTS AT ALL, given those alerting rules already exist:
#   They run INSIDE the stack they watch, so they cannot report its birth.
#   - If Prometheus never becomes available, nothing evaluates the rule that
#     would say so.
#   - If kube-state-metrics is down, every kube_* series disappears and the rules
#     compare EMPTY VECTORS — they stop firing rather than alerting.
#   Both are load-bearing, not hypothetical: kube-state-metrics sat in
#   CrashLoopBackOff on the dev cell for 25 days behind a NetworkPolicy that
#   denied the API ClusterIP, and no alert fired the entire time, because the
#   alerts depended on the component that was down.
#
#   This barrier runs from the Phase-4 execution context — the Omnistrate runner,
#   outside the cluster's observability stack — which is precisely why it can see
#   what that stack cannot say about itself.
#
# WHAT IT DELIBERATELY DOES NOT ASSERT:
#   Public ingress, DNS, TLS certificates, and alert DELIVERY (Slack, customer
#   webhooks) are all out of scope. Those depend on external systems, and we must
#   never build a world where:
#       a Slack outage -> a new customer cell cannot be created
#   The invariant is "the monitoring system came alive", not "every notification
#   integration delivered successfully".
# =============================================================================

locals {
  # Gated on the INSTANCE's routing flag. An instance on grafana_mode = "cloud"
  # egresses telemetry to Grafana Cloud and has no in-VPC stack to assert on.
  obs_gate_count = var.grafana_mode == "self_hosted" ? 1 : 0

  # local.observability_ready_name / _present live in cell_gates.tf with the
  # other cell -> instance gates.

  # Bump ONLY to force every existing instance to re-run the barrier — i.e. when
  # the assertions below change in a way that older instances should be re-checked
  # against. Bumping it re-runs the Job on the next apply for every self-hosted
  # instance, so treat it as a fleet-wide operation, not a routine edit.
  observability_readiness_contract_version = 1

  obs_namespace = "pavo-observability"

  # Same pinned multi-arch image the Zitadel readiness Job uses (curl + jq).
  obs_readiness_image = "docker.io/alpine/k8s@sha256:66dd3f7db6c4cf152b688d83aad11ceed9eb2da0c4e7de1034c7d4ccea1b55ef"
}

# One-time semantics live here, NOT in the Job's name alone. `triggers_replace`
# is limited to instance identity plus the contract version, so an unrelated
# change elsewhere in this module (an image bump, a new bucket) does NOT re-run
# the barrier. Without this the barrier would degrade into exactly the permanent
# health check the invariant says it must not be, and an unrelated app change
# would start failing because shared Prometheus was briefly unhealthy.
resource "terraform_data" "observability_convergence" {
  count = local.obs_gate_count

  triggers_replace = {
    instance_id      = var.instance_id
    contract_version = local.observability_readiness_contract_version
  }
}

resource "kubernetes_job_v1" "observability_readiness" {
  count = local.obs_gate_count

  # Fail fast, with an actionable message, when the instance is routed at a cell
  # that was never bootstrapped for observability. Same shape as the eck_ready
  # precondition — this catches the misconfiguration BEFORE spending 10 minutes
  # in a Job that could never have passed.
  #
  # This also fires on an ALREADY-CREATED instance whose cell later drops
  # enable_observability, which is the intended true->false hazard signal.
  lifecycle {
    # The contract version is the ONLY control over re-running this barrier.
    #
    # Without this, the kubernetes provider treats spec.template as ForceNew, so
    # bumping the probe image — or any other routine edit to the pod spec —
    # would replace the completed Job and re-run every assertion. That is the
    # exact degradation the invariant forbids: an unrelated change starts
    # failing an app apply because shared Prometheus happened to be unhealthy at
    # that moment.
    #
    # The trade-off is deliberate and worth stating plainly: a change to the
    # image or pod spec does NOT reach existing instances until
    # observability_readiness_contract_version is bumped. If you change what the
    # barrier runs and want the fleet re-checked against it, bump the version in
    # the same commit — that is what it is for.
    ignore_changes = [spec[0].template]

    precondition {
      condition     = local.observability_ready_present
      error_message = <<-EOT
        grafana_mode = "self_hosted" routes this instance's telemetry to the
        in-VPC observability stack on cell ${var.eks_cluster_name}, but
        ${local.observability_ready_name} does not exist, so that cell was never
        bootstrapped with the stack.

        Fix on the CELL (pavo-bootstrap-aws), not here:
          1. set enable_observability = true (and observability_grafana_host)
             in cells/${var.eks_cluster_name}/${var.eks_cluster_name}.tfvars
          2. apply pavo-bootstrap-aws for that cell
          3. re-run this instance

        Or set grafana_mode = "cloud" on this instance if telemetry is allowed to
        leave the VPC.
      EOT
    }
  }

  metadata {
    # Name is derived from the barrier resource, so replacing that resource
    # (instance identity or contract version changed) creates a NEW Job rather
    # than trying to mutate a completed one, which Kubernetes forbids.
    name      = "pavo-obs-readiness-${substr(sha256(terraform_data.observability_convergence[0].id), 0, 10)}"
    namespace = var.instance_id
  }

  spec {
    backoff_limit = 1
    # ABOVE the script's own 600s convergence budget, deliberately. The script
    # should always be the thing that fails, because it names which check did
    # not pass; this is only a backstop for a wedged container.
    active_deadline_seconds    = 720
    ttl_seconds_after_finished = 600

    template {
      metadata {}
      spec {
        restart_policy       = "Never"
        enable_service_links = false

        # The probe makes only outbound HTTP calls, so let it schedule anywhere
        # rather than waiting on a workload node. On a fresh cell the workload
        # pool may still be filling in, and a barrier that cannot itself be
        # scheduled would report a false failure about someone else's stack.
        toleration {
          key      = "CriticalAddonsOnly"
          operator = "Exists"
        }

        container {
          name    = "readiness"
          image   = local.obs_readiness_image
          command = ["/bin/bash", "-c"]
          args = [<<-EOT
            set -euo pipefail

            # ONE end-to-end wall-clock budget, shared by every check, rather
            # than a per-check attempt count.
            #
            # A per-check count cannot be reasoned about: an attempt costs up to
            # `--max-time 8` plus `sleep 5`, so "60 attempts" is up to 13 minutes
            # for ONE check and ~65 minutes for five. The Job's
            # active_deadline_seconds would kill it partway through the second
            # check, and every later check would silently never get the retry
            # budget its code claimed to give it.
            #
            # With a shared deadline the arithmetic is honest: checks that pass
            # quickly leave their unused time to the ones that do not, and the
            # total is bounded by a number that actually matches the Job's own
            # deadline. active_deadline_seconds is set ABOVE this budget so the
            # script reports the failure itself, with which check failed, instead
            # of being killed with no explanation.
            BUDGET_SECONDS=600
            DEADLINE=$(( $(date +%s) + BUDGET_SECONDS ))
            remaining() { echo $(( DEADLINE - $(date +%s) )); }

            # Both retry loops below set a success flag and assert it AFTER the
            # loop, rather than failing inside the loop on `[ "$i" = <bound> ]`.
            # That shape looks equivalent and is not: it couples the guard to a
            # magic constant matching the loop bound, so changing the bound
            # without changing the constant makes the loop fall through to
            # SUCCESS. Caught exactly that way while testing this file — a check
            # that silently stops checking is the failure mode this barrier
            # exists to prevent, so it must not be reintroduced here.
            probe() {
              local label="$1" url="$2" ok=0
              echo "asserting $label ..."
              while [ "$(remaining)" -gt 0 ]; do
                if curl -fsS --connect-timeout 3 --max-time 8 "$url" >/dev/null 2>&1; then
                  ok=1
                  break
                fi
                sleep 5
              done
              if [ "$ok" != 1 ]; then
                echo "FATAL: $label did not become ready within the $${BUDGET_SECONDS}s"
                echo "       convergence budget ($url)"
                return 1
              fi
              echo "  $label OK ($(remaining)s of budget left)"
            }

            NS="${local.obs_namespace}"
            PROM="http://pavo-observability-prometheus-server.$NS.svc"

            # --- the serving layer -------------------------------------------
            probe "Prometheus"     "$PROM/-/ready"
            probe "Alertmanager"   "http://pavo-observability-prometheus-alertmanager.$NS.svc:9093/-/ready"
            # Grafana's /api/health reports DATABASE status and returns 503 when
            # it cannot reach Postgres, so this covers the Postgres StatefulSet
            # transitively. There is deliberately no separate Postgres probe.
            probe "Grafana"        "http://pavo-observability-grafana.$NS.svc/api/health"
            probe "OTel collector" "http://pavo-otel-collector.$NS.svc:8888/metrics"

            # --- the DATA PATH, which is the point ---------------------------
            # Everything above proves processes are listening. This proves the
            # pipeline actually carries data: Prometheus must be SERVING kube_*
            # series, which is only true if kube-state-metrics is running AND
            # being scraped successfully.
            #
            # This is the assertion that would have caught the 25-day
            # kube-state-metrics outage on the dev cell, where every process
            # above was healthy and no metrics about workloads existed.
            echo "asserting kube-state-metrics series are being served ..."
            series_ok=0
            while [ "$(remaining)" -gt 0 ]; do
              n="$(curl -fsS --connect-timeout 3 --max-time 8 \
                    --data-urlencode 'query=count(kube_deployment_spec_replicas)' \
                    "$PROM/api/v1/query" 2>/dev/null \
                    | jq -r '.data.result[0].value[1] // "0"' 2>/dev/null || echo 0)"
              if [ "$${n:-0}" -gt 0 ] 2>/dev/null; then
                series_ok=1
                echo "  kube_deployment_spec_replicas: $n series OK"
                break
              fi
              sleep 5
            done
            if [ "$series_ok" != 1 ]; then
              echo "FATAL: Prometheus is up but serving no kube_* series."
              echo "       kube-state-metrics is down or not being scraped."
              echo "       Every workload-health alert on this cell is silently"
              echo "       inert until this is fixed — the rules compare empty"
              echo "       vectors and never fire."
              exit 1
            fi

            echo "OBSERVABILITY CONVERGED"
          EOT
          ]
        }
      }
    }
  }

  wait_for_completion = true

  # Above active_deadline_seconds (720s) so Kubernetes terminates the Job and
  # Terraform reports that, rather than Terraform timing out first and leaving a
  # running Job behind.
  timeouts {
    create = "15m"
    update = "15m"
  }

  depends_on = [kubectl_manifest.instance_namespace]
}
