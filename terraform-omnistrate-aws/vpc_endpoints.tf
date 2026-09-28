# =============================================================================
# VPC Interface Endpoints (AWS PrivateLink)
# -----------------------------------------------------------------------------
# Keep AWS-service API traffic OFF the public internet (NAT gateway). Without
# these, calls to Bedrock, KMS, Secrets Manager, etc. leave the VPC via NAT to
# the public AWS endpoints. Bedrock carries prompts / documents / embeddings;
# KMS + Secrets Manager carry key + secret material — so PrivateLink here is the
# core of the "no customer data leaves the VPC" (zero-egress) posture.
#
# S3 + DynamoDB use *gateway* endpoints, which the deployment cell (Omnistrate)
# already provisions — so they are intentionally NOT recreated here.
# =============================================================================

variable "enable_vpc_endpoints" {
  description = <<-EOT
    Provision VPC interface endpoints (AWS PrivateLink) for Bedrock, KMS,
    Secrets Manager, ECR, SQS, SNS and STS so those AWS API calls never traverse
    the public internet. Default true — small hourly cost per endpoint, and
    required for the zero-egress posture on strict BYOC (e.g. healthcare).
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
      "bedrock-runtime", # LLM inference + embeddings — prompts, documents, queries
      "kms",             # customer-managed key encrypt/decrypt
      "secretsmanager",  # RDS master password via External Secrets Operator
      "ecr.api",         # container image pulls — registry auth
      "ecr.dkr",         # container image pulls — layer download
      "sqs",             # queues — may carry references to customer data
      "sns",             # topics
      "sts",             # IRSA / AssumeRoleWithWebIdentity token exchange
    ],
    # SES v2 API endpoint — transactional email SendEmail stays on the AWS
    # backbone (no VPC internet egress) when email is enabled.
    local.email_enabled ? ["email"] : [],
  )
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
  count       = var.enable_vpc_endpoints ? 1 : 0
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
  for_each = var.enable_vpc_endpoints ? toset(local.vpc_interface_endpoint_services) : []

  vpc_id              = var.vpc_id
  service_name        = "com.amazonaws.${var.aws_region}.${each.value}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = local.vpc_endpoint_subnet_ids
  security_group_ids  = [aws_security_group.vpc_endpoints[0].id]
  private_dns_enabled = true

  tags = {
    Name = "pavo-vpce-${each.value}-${var.instance_id}"
  }
}
