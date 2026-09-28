# -----------------------------------------------------------------------------
# Terraform Providers — pavoInfra (per-instance, Omnistrate-applied)
# -----------------------------------------------------------------------------
# Omnistrate manages the EKS cluster. This module provisions per-instance
# resources only:
#   - RDS PostgreSQL, ElastiCache Redis, S3, SNS+SQS, EFS
#   - IAM role + IRSA (workload identity)
#   - per-instance K8s namespace + ExternalSecret + EFS StorageClass
#   - Elastic Cloud deployment + API key
#
# All cell-scoped resources (EKS access entry, ESO/Reloader Helm, EBS CSI,
# cluster-scoped K8s objects) live in `pavo-bootstrap-aws/`. All identity
# resources (Zitadel) live in `pavo-customer-bootstrap/`. See repo
# README → "Module ownership" for the full split.
#
# Provider list reflects the post-rescope reality:
#   - `helm` declared but no longer consumed by any active resource. The
#     Sigstore Policy Controller release that briefly used it (PR #90) has
#     moved to pavo-bootstrap-aws/. The declaration stays around the
#     `removed { helm_release.policy_controller }` shim at the bottom of
#     main.tf — drop the provider in a cleanup PR once that shim is gone.
#   - `zitadel` removed (Zitadel resources moved to customer-bootstrap;
#     pavoInfra only receives the computed identity values as apiParameters).
# -----------------------------------------------------------------------------

terraform {
  required_version = ">= 1.7"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.33.0, < 6.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.30"
    }
    kubectl = {
      source  = "alekc/kubectl"
      version = ">= 2.2.0, < 3.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.13"
    }
    ec = {
      source  = "elastic/ec"
      version = "~> 0.12"
    }
    elasticstack = {
      source = "elastic/elasticstack"
      # Bumped from ~> 0.11 because in 0.11.x the resource-level
      # `elasticsearch_connection` block on
      # `elasticstack_elasticsearch_security_api_key` is marked deprecated and
      # is not honored at refresh time — provider init falls back to (empty)
      # provider-level config and fails with "elasticsearch client is not
      # configured." See Elastic issue #546. v0.15+ documents
      # `elasticsearch_connection` as fully supported (non-deprecated), which
      # is the path PR #112 relies on.
      version = "~> 0.15"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.11"
    }
  }

  # Omnistrate manages Terraform state internally - do not add backend blocks
}

provider "aws" {
  region = var.aws_region
  # No credentials - Omnistrate provides execution identity via AssumeRole

  default_tags {
    tags = local.aws_default_tags
  }
}

# -----------------------------------------------------------------------------
# Kubernetes provider — authenticated via EKS cluster credentials
# Used to create cluster-level resources (StorageClass, IngressClass) before Helm
# -----------------------------------------------------------------------------

data "aws_eks_cluster" "primary" {
  name = var.eks_cluster_name
}

# EKS auth for the kubernetes / kubectl / helm providers — exec credentials.
# -----------------------------------------------------------------------------
# Each provider runs `aws eks get-token` per Kubernetes API request, so the
# token is short-lived and auto-refreshed — a long apply cannot outlive a
# single static STS token. This relies on the AWS CLI being present on the
# Omnistrate Terraform runner image (Omnistrate added it in 2026-05; the
# runner's execution role provides credentials, region is passed explicitly).

locals {
  eks_exec_api_version = "client.authentication.k8s.io/v1beta1"
  eks_exec_command     = "aws"
  eks_exec_args        = ["eks", "get-token", "--cluster-name", var.eks_cluster_name, "--region", var.aws_region, "--output", "json"]
}

provider "kubernetes" {
  host                   = data.aws_eks_cluster.primary.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.primary.certificate_authority[0].data)

  exec {
    api_version = local.eks_exec_api_version
    command     = local.eks_exec_command
    args        = local.eks_exec_args
  }
}

provider "kubectl" {
  host                   = data.aws_eks_cluster.primary.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.primary.certificate_authority[0].data)
  load_config_file       = false

  exec {
    api_version = local.eks_exec_api_version
    command     = local.eks_exec_command
    args        = local.eks_exec_args
  }
}

# -----------------------------------------------------------------------------
# Helm provider — kept around the `removed { helm_release.policy_controller }`
# shim at the bottom of main.tf. No active resources consume helm in pavoInfra
# anymore: ESO + Reloader live in pavo-bootstrap-aws, and the Sigstore Policy
# Controller release that briefly used helm here (PR #90) also moved to
# bootstrap. Drop the provider + the shim in the same cleanup PR.
# Auth mirrors the kubernetes/kubectl providers above.
# -----------------------------------------------------------------------------
provider "helm" {
  kubernetes {
    host                   = data.aws_eks_cluster.primary.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.primary.certificate_authority[0].data)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = local.eks_exec_args
    }
  }
}

provider "ec" {
  apikey = var.elastic_api_key
}

# Elasticstack provider — sources its connection from ec_deployment.onboarding_es.
# An earlier attempt (#112) moved this to a resource-level elasticsearch_connection
# block with an empty provider here, on the theory that terraform destroy could then
# succeed even when ec_deployment had been deleted out-of-band. In practice the
# elasticstack provider only uses the resource-level block at Create/Update/Delete,
# NOT at refresh — refresh uses the provider client configured here. With an empty
# provider the client has no endpoint, refresh of any in-state elasticstack_*
# resource fails immediately with "Unable to get Elasticsearch client", and the
# upgrade workflow can't even produce a plan. Reverted in #114.
#
# The "manual ec_deployment delete leaves state stuck" scenario this was trying to
# fix no longer requires this hack: #112 also removed prevent_destroy from
# ec_deployment, so normal terraform destroy handles it via dependency order
# (app_api_key destroys before ec_deployment, both still in state at plan time).
provider "elasticstack" {
  elasticsearch {
    # ec_deployment is count-gated on es_mode = "cloud". one(...) yields null when
    # es_mode = "self_hosted" (no Elastic Cloud); the provider is then simply never
    # used (no elasticstack_* resource exists), so an empty endpoints list is fine.
    endpoints = compact([one(ec_deployment.onboarding_es[*].elasticsearch.https_endpoint)])

    api_key  = var.elasticsearch_api_key != "" ? base64encode(var.elasticsearch_api_key) : null
    username = var.elasticsearch_api_key != "" ? null : one(ec_deployment.onboarding_es[*].elasticsearch_username)
    password = var.elasticsearch_api_key != "" ? null : one(ec_deployment.onboarding_es[*].elasticsearch_password)
  }
}
