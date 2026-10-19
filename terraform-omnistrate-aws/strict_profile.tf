# =============================================================================
# Strict posture hosting kill switch
# =============================================================================
# network_posture=strict is the central control. Helm layers (spec-byoc.yaml)
# force LLM / computer / SaaS env. This file only guards the four hosting
# modes: a strict cell must already be self_hosted. Posture does not swap
# Elastic Cloud / Temporal Cloud / central Zitadel / Grafana Cloud on a live
# cell (data replacement). Set the four flags at instance CREATE.
#
# A cell that already created the instance with all four self_hosted flags
# sees this guard as a no-op.
# =============================================================================

locals {
  effective_es_mode       = var.network_posture == "strict" ? "self_hosted" : var.es_mode
  effective_grafana_mode  = var.network_posture == "strict" ? "self_hosted" : var.grafana_mode
  effective_temporal_mode = var.network_posture == "strict" ? "self_hosted" : var.temporal_mode
  effective_zitadel_mode  = var.network_posture == "strict" ? "self_hosted" : var.zitadel_mode
}

resource "terraform_data" "strict_hosting_guard" {
  lifecycle {
    precondition {
      condition = (
        var.network_posture != "strict" ||
        (
          var.es_mode == "self_hosted" &&
          var.grafana_mode == "self_hosted" &&
          var.temporal_mode == "self_hosted" &&
          var.zitadel_mode == "self_hosted"
        )
      )
      error_message = <<-EOT
        network_posture = "strict" requires es_mode, grafana_mode, temporal_mode,
        and zitadel_mode = self_hosted at instance create. Posture does not swap
        those backends on a live cell (that would replace Elastic Cloud / Temporal
        Cloud / central Zitadel / Grafana Cloud). Set the four flags at CREATE,
        or recreate the instance.
      EOT
    }
  }
}
