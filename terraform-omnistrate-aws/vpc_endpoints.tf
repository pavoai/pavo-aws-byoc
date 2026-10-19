# =============================================================================
# VPC Interface Endpoints (AWS PrivateLink)
# -----------------------------------------------------------------------------
# Keep AWS-service API traffic OFF the public internet (NAT gateway). Without
# these, calls to Bedrock, KMS, Secrets Manager, IAM, RDS, etc. leave the VPC
# via NAT to the public AWS endpoints. On a private cell there is no NAT, so
# instance tofu and the workload cannot function unless these names resolve
# to PrivateLink.
#
# S3 + DynamoDB use *gateway* endpoints, which the deployment cell (Omnistrate)
# already provisions — so they are intentionally NOT recreated here.
#
# REUSE — live describe, not a hardcoded private-cell skip list.
# A second interface endpoint cannot set private_dns_enabled when the service
# hostname is already claimed in the VPC. We describe available Interface
# VPCEs and skip a service only when a *foreign* private-DNS endpoint exists
# (Name != pavo-vpce-<service>-<instance_id>).
#
# Why the Name exception exists:
#   - Endpoints this module already owns (Name = pavo-vpce-<svc>-<instance_id>)
#     must stay in for_each or the next apply destroys them.
#   - Omnistrate cell leftovers (ecr.api / ecr.dkr / sts) use other Names →
#     foreign → skip forever.
#   - Same-name orphans (created outside state with this module's Name) look
#     like ours. Code will try to create them. Delete those before apply;
#     do not terraform import (Omnistrate tofu cannot import easily).
#   - Cell bootstrap (pavo-bootstrap-aws) owns the plan-refresh APIs
#     (kms, secretsmanager, iam, rds, elasticache, sns, sqs,
#     elasticfilesystem, email) as pavo-vpce-<svc>-<eks_cluster_name>.
#     Those are foreign here and must exist *before* the first instance
#     plan on a no-NAT cell.
# =============================================================================

variable "enable_vpc_endpoints" {
  description = <<-EOT
    Provision VPC interface endpoints (AWS PrivateLink) for Bedrock (control
    plane + runtime), KMS, Secrets Manager, ECR, SQS, SNS, STS, RDS,
    ElastiCache, EFS, IAM, and SES (when email is enabled) so those AWS API
    calls never traverse the public internet. Default true — small hourly
    cost per endpoint, and required for the zero-egress posture on strict
    BYOC (e.g. healthcare) and for instance tofu on a private cell (no NAT).
    Set false only for cost-sensitive non-strict deployments that accept
    AWS-service traffic over the NAT gateway.
  EOT
  type        = bool
  default     = true
}

locals {
  # Interface-endpoint services. Gateway-type services (s3, dynamodb) are
  # provisioned by the deployment cell and deliberately excluded.
  vpc_interface_endpoint_services = concat(
    [
      "bedrock-runtime",   # LLM inference + embeddings — prompts, documents, queries
      "bedrock",           # Bedrock control plane (ListFoundationModels, etc.)
      "kms",               # customer-managed key encrypt/decrypt
      "secretsmanager",    # RDS master password via External Secrets Operator
      "ecr.api",           # container image pulls — registry auth
      "ecr.dkr",           # container image pulls — layer download
      "sqs",               # queues — may carry references to customer data
      "sns",               # topics
      "sts",               # IRSA / AssumeRoleWithWebIdentity token exchange
      "rds",               # postgres / Temporal DBs
      "elasticfilesystem", # EFS CSI / file system APIs
      "elasticache",       # Redis replication groups
      "iam",               # CreateRole / IRSA policies — global, not regional
    ],
    # SES v2 API endpoint — transactional email SendEmail stays on the AWS
    # backbone (no VPC internet egress) when email is enabled.
    local.email_enabled ? ["email"] : [],
  )

  # IAM is com.amazonaws.iam (no region). Everything else is regional.
  vpc_endpoint_service_name = {
    for s in local.vpc_interface_endpoint_services :
    s => s == "iam" ? "com.amazonaws.iam" : "com.amazonaws.${var.aws_region}.${s}"
  }
}

# Live Interface VPCEs in this VPC. hashicorp/aws 5.x has no plural
# aws_vpc_endpoints data source (CI installs 5.100.0), so we list VPCE ENIs
# (gateway endpoints have none), parse the vpce-id from the ENI description,
# and look each one up with the singular data source. 0 ENIs is a valid
# empty set — that is what lets a cell add RDS/IAM/etc. without a lookup miss.
# ec2:DescribeNetworkInterfaces / DescribeVpcEndpoints are already granted.
data "aws_network_interfaces" "vpc_endpoint" {
  filter {
    name   = "vpc-id"
    values = [var.vpc_id]
  }
  filter {
    name   = "interface-type"
    values = ["vpc_endpoint"]
  }
}

data "aws_network_interface" "vpc_endpoint" {
  for_each = toset(data.aws_network_interfaces.vpc_endpoint.ids)
  id       = each.value
}

locals {
  existing_interface_vpce_ids = toset(compact([
    for eni in data.aws_network_interface.vpc_endpoint :
    try(regex("vpce-[a-z0-9]+", eni.description), "")
  ]))
}

data "aws_vpc_endpoint" "existing_interface" {
  for_each = local.existing_interface_vpce_ids
  id       = each.value
}

locals {
  # Map each live endpoint to the same service key we use in for_each.
  existing_interface_service_key = {
    for id, ep in data.aws_vpc_endpoint.existing_interface :
    id => ep.service_name == "com.amazonaws.iam" ? "iam" : trimprefix(ep.service_name, "com.amazonaws.${var.aws_region}.")
  }

  # Skip only when private DNS is already claimed by something we do not name.
  foreign_private_dns_services = toset([
    for id, ep in data.aws_vpc_endpoint.existing_interface :
    local.existing_interface_service_key[id]
    if ep.vpc_endpoint_type == "Interface" && ep.state == "available" && ep.private_dns_enabled && try(ep.tags["Name"], "") != "pavo-vpce-${local.existing_interface_service_key[id]}-${var.instance_id}"
  ])

  vpc_interface_endpoints_to_create = var.enable_vpc_endpoints ? setsubtract(
    toset(local.vpc_interface_endpoint_services),
    local.foreign_private_dns_services,
  ) : toset([])
}

# One subnet per AZ — interface endpoints permit at most one subnet per
# Availability Zone, so we cannot pass data.aws_subnets.private.ids directly
# (a cell may expose multiple private subnets in the same AZ).
data "aws_subnet" "private_by_id" {
  for_each = var.enable_vpc_endpoints ? toset(data.aws_subnets.private.ids) : []
  id       = each.value
}

locals {
  _private_subnets_by_az = {
    for id, s in data.aws_subnet.private_by_id : s.availability_zone => id...
  }
  vpc_endpoint_subnet_ids = [for az, ids in local._private_subnets_by_az : ids[0]]
}

resource "aws_security_group" "vpc_endpoints" {
  count       = length(local.vpc_interface_endpoints_to_create) > 0 ? 1 : 0
  name        = "pavo-vpce-sg-${var.instance_id}"
  description = "HTTPS from within the VPC to PrivateLink interface endpoints"
  vpc_id      = var.vpc_id

  ingress {
    description = "HTTPS from within the VPC"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.eks.cidr_block]
  }

  egress {
    description = "Return traffic within the VPC"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [data.aws_vpc.eks.cidr_block]
  }

  tags = {
    Name = "pavo-vpce-sg-${var.instance_id}"
  }
}

resource "aws_vpc_endpoint" "interface" {
  for_each = local.vpc_interface_endpoints_to_create

  vpc_id              = var.vpc_id
  service_name        = local.vpc_endpoint_service_name[each.value]
  vpc_endpoint_type   = "Interface"
  subnet_ids          = local.vpc_endpoint_subnet_ids
  security_group_ids  = [aws_security_group.vpc_endpoints[0].id]
  private_dns_enabled = true

  tags = {
    Name = "pavo-vpce-${each.value}-${var.instance_id}"
  }
}
