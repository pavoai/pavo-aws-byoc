# =============================================================================
# Mirrored images consumed through the shared artifact plane
# =============================================================================
# Both standard and strict cells now use the same central artifact plane for
# runtime images. The Terraform-managed components below therefore always point
# at the mirrored ECR copies instead of switching on network_posture.
#
# The artifact plane copies these images to
#   <registry>/omnistrate/images/pavo/<upstream-host>/<path>
# ECR stores them by digest only, so every rewrite is digest-pinned.

locals {
  artifact_plane = "493807289773.dkr.ecr.us-east-2.amazonaws.com/omnistrate/images/pavo"

  image = {
    postgres_16_alpine  = "${local.artifact_plane}/public.ecr.aws/docker/library/postgres@sha256:721873c34ceb9f8d8fc265984940dc982404c105f19ad51be9fdc5970a6080ea"
    alpine_k8s          = "${local.artifact_plane}/docker.io/alpine/k8s@sha256:66dd3f7db6c4cf152b688d83aad11ceed9eb2da0c4e7de1034c7d4ccea1b55ef"
    zitadel             = "${local.artifact_plane}/ghcr.io/zitadel/zitadel@sha256:32834d46240c5ece9f86c5e5f706b167c2064fba76bbf9213e3494023c38ca5d"
    es_exporter         = "${local.artifact_plane}/quay.io/prometheuscommunity/elasticsearch-exporter@sha256:4786d49bef9ec045c155d5544abc420e6f58394170db7b6a05c5e7a5f15fb9ed"
    curl                = "${local.artifact_plane}/docker.io/curlimages/curl@sha256:a73e4b2a41674e127042302efd0c237a44b029ca616d640945597666cddf53ca"
    elasticsearch       = "${local.artifact_plane}/docker.elastic.co/elasticsearch/elasticsearch@sha256:86d0a30f420470d9cd4102cdf380c5a458bd6ccbbd3f54f7332d3b0b562431b8"
    kibana              = "${local.artifact_plane}/docker.elastic.co/kibana/kibana@sha256:55730ce4291cddc28ef700c9fbb9c337c8dee50b7f86d4640bcd82363f1fb92b"
    temporal_server     = "${local.artifact_plane}/ghcr.io/pavoai/mirror/temporalio/server"
    temporal_admin      = "${local.artifact_plane}/ghcr.io/pavoai/mirror/temporalio/admin-tools"
    temporal_ui         = "${local.artifact_plane}/ghcr.io/pavoai/mirror/temporalio/ui:2.53.0@sha256:810eba47f77a89b0e64e2e751478ca585d037bbd90c0951a2974a92a6c5adeb9"
    nginx               = "${local.artifact_plane}/public.ecr.aws/nginx/nginx:1.29-alpine@sha256:72c9b856fee09b02f9e5ee29ab2b55ae9a3c3b59cf094baef1d05f5914d8cb17"
    zitadel_provisioner = "${local.artifact_plane}/${var.zitadel_provisioner_image}"
    temporal_codec      = trimspace(var.temporal_codec_image) != "" ? "${local.artifact_plane}/${trimspace(var.temporal_codec_image)}" : var.temporal_codec_image
  }
}
