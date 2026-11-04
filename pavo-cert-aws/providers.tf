# -----------------------------------------------------------------------------
# Terraform Providers — pavoCert (per-instance, Omnistrate-applied)
# -----------------------------------------------------------------------------
# Deliberately tiny: one AWS provider, no Kubernetes. Nothing here needs the
# cluster, so the module plans on a fresh cell and fails fast on its one gate
# (main.tf) instead of on a hung API call. Provider constraint mirrors
# terraform-omnistrate-aws so the artifact-plane mirror already serves it.
# -----------------------------------------------------------------------------

terraform {
  required_version = ">= 1.7"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.33.0, < 6.0"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      managed_by  = "pavo"
      customer    = var.customer_name
      environment = "prod"
      instance    = var.instance_id
    }
  }
}
