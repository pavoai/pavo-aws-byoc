# Architecture

A Pavo deployment on AWS uses two Terraform modules published here, applied by
different parties, with separate state. Identity setup is a third step that
is not in this review copy.

## The stages

| Stage | Module | Who applies it | When | Credentials | State |
|---|---|---|---|---|---|
| 1. Cell bootstrap | `pavo-bootstrap-aws/` | You | Once per deployment cell (one EKS cluster), and on upgrades you choose | Your AWS credentials | Your S3 backend (`scripts/create-state-backend.sh` creates one) |
| 2. Instance infrastructure | `terraform-omnistrate-aws/` | Omnistrate's Terraform runner, in your account | Every instance create, modify, upgrade or delete | The Omnistrate runner role in your account, with cluster-admin through the EKS access entry stage 1 creates | Omnistrate-managed |
| 3. Identity (not published) | Pavo-applied, or an in-cluster Job that stage 2 creates | Cloud identity: Pavo operators. Self-hosted identity: a Kubernetes Job | Once per customer | Cloud: Pavo's credentials for its identity service. Self-hosted: a machine key for your in-VPC Zitadel | Cloud: a Pavo-owned bucket. Self-hosted: an S3 bucket in your account |

Stage 1 must run before stage 2. Stage 2 reads the permission boundary's ARN
from `/pavo/shared/permission_boundary_arn` in SSM and fails without it.

## What each stage creates

### Stage 1: `pavo-bootstrap-aws/`

- **IAM:** the `pavo-permission-boundary-shared` policy
  (`policy-statements.json`), which caps every role stage 2 creates; the
  External Secrets Operator (ESO) role, limited to Secrets Manager and KMS.
- **EKS access:** an access entry giving the Omnistrate runner role
  `AmazonEKSClusterAdminPolicy` on this cluster only.
- **Cluster add-ons (Helm):** External Secrets Operator, Stakater Reloader, the
  Sigstore policy controller, and optionally the ECK operator
  (`enable_eck`) and an in-VPC observability stack (`enable_observability`).
- **Kubernetes objects:** the `pd-balanced` storage class (on the cell key with `pd_balanced_use_cell_key`; plus `gp3-cmk`,
  backed by the cell key, with `enable_observability`), the
  `pavo-nginx` ingress class, a Let's Encrypt cluster issuer, optionally a
  private CA (`install_private_ca`), and the image-signature policies.
- **Networking:** S3 and DynamoDB gateway endpoints, only for route tables the
  existing endpoints don't already cover.
- **Other:** SSM parameters under `/pavo/shared/` and `/pavo/cells/<cluster>/`,
  including a one-cell-per-account guard, and an S3 bucket used as a
  Terraform provider mirror for strict cells.

### Stage 2: `terraform-omnistrate-aws/`

Per instance:

- **Data stores:** RDS PostgreSQL (and a second one for self-hosted Temporal),
  three ElastiCache Redis groups, an EFS file system, S3 buckets, SNS topics
  and SQS queues.
- **IAM:** a workload role for the application pods (IRSA), a KEDA role that
  reads SQS queue depth, and, depending on mode, roles for Elasticsearch
  snapshots and for the identity Job. All are created with the stage 1
  permission boundary.
- **Networking:** security groups for RDS, Redis, EFS and the VPC interface
  endpoints; interface endpoints for Bedrock, KMS, Secrets Manager, ECR, SQS,
  SNS and STS (and SES when email is enabled); and, with
  `network_posture = "strict"`, default-deny egress NetworkPolicies.
- **Kubernetes:** the instance namespace, ExternalSecrets that sync the
  database password, and configuration Secrets and ConfigMaps.
- **Optional components** (by `es_mode`, `temporal_mode`, `zitadel_mode`,
  `grafana_mode`): Elasticsearch either on Elastic Cloud or in-cluster (ECK);
  Temporal either on Temporal Cloud or in-cluster; Zitadel either Pavo's
  hosted service or in-cluster. Telemetry stays in-VPC by default
  (`grafana_mode = self_hosted`, which needs `enable_observability` on the
  cell); `cloud` sends metrics to Grafana Cloud.

See [inputs-contract.md](inputs-contract.md) for every input and its source.

### Stage 3: identity (not in this repository)

One Zitadel organization, project and OIDC application for your hostname,
plus optionally one external identity provider (Google, OIDC or SAML) and a
login policy. With cloud identity these live in Pavo's shared Zitadel tenant,
one organization per customer; nothing is created in your account. The
Terraform that creates those objects is not published here.

## Modes

| Input | Values | Changes |
|---|---|---|
| `network_posture` | `standard`, `strict` | Strict adds default-deny egress NetworkPolicies, an internal load balancer, private-CA certificates and provider installs from the in-account mirror |
| `es_mode` | `cloud`, `self_hosted` | Elastic Cloud deployment, or an in-cluster ECK cluster with S3 snapshots |
| `grafana_mode` | `self_hosted` (default), `cloud` | In-VPC Prometheus/Grafana, or telemetry egress to Grafana Cloud |
| `temporal_mode` | `cloud`, `self_hosted` | Temporal Cloud, or an in-cluster Temporal with its own RDS |
| `zitadel_mode` | `cloud`, `self_hosted` | Pavo's hosted identity, or an in-cluster Zitadel configured by the stage 3 Job |

## Teardown

Deleting an instance destroys its stage 2 resources, subject to the
teardown controls in `terraform-omnistrate-aws/README.md` ("Teardown
contract"), for example RDS deletion protection and final snapshots. Stage 1
resources stay until you destroy that module; the SSM one-cell guard has
`prevent_destroy` set.
