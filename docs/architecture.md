# Architecture

A Pavo deployment on AWS uses the Terraform modules published here, applied by
different parties, with separate state. Identity setup is a third step that
is not in this review copy.

## The stages

| Stage | Module | Who applies it | When | Credentials | State |
|---|---|---|---|---|---|
| 1. Cell bootstrap | `pavo-bootstrap-aws/` | You | Once per deployment cell (one EKS cluster), and on upgrades you choose | Your AWS credentials | Your S3 backend (`scripts/create-state-backend.sh` creates one) |
| Edge certificate (strict only) | `pavo-cert-aws/` | Omnistrate's Terraform runner, in your account. With a custom `app_domain`, you add one validation CNAME in your DNS during the 60-minute wait (Pavo sends name and value); Pavo adds the `<customer>.pavoai.dev` one | Every strict instance create, before stage 2 | The Omnistrate runner role | Omnistrate-managed |
| 2. Instance infrastructure | `terraform-omnistrate-aws/` | Omnistrate's Terraform runner, in your account | Every instance create, modify, upgrade or delete | The Omnistrate runner role in your account, with cluster-admin through the EKS access entry stage 1 creates | Omnistrate-managed |
| 3. Identity (not published) | Pavo-applied, or an in-cluster Job that stage 2 creates | Cloud identity: Pavo operators. Self-hosted identity: a Kubernetes Job | Once per customer | Cloud: Pavo's credentials for its identity service. Self-hosted: a machine key for your in-VPC Zitadel | Cloud: a Pavo-owned bucket. Self-hosted: an S3 bucket in your account |

Stage 1 must run before stage 2. Stage 2 reads the permission boundary's ARN
from `/pavo/shared/permission_boundary_arn` in SSM and fails without it.

Omnistrate stores the edge-certificate and stage 2 state as Kubernetes
Secrets (`tfstate-*`) in the `omnistrate-terraform` namespace of your
cluster, so the state file itself stays in your account ("Omnistrate manages
the Terraform state backend using Kubernetes secrets", Omnistrate docs). It is
encrypted as your cluster's Secrets are; the cell cluster is Omnistrate-created
and sets no KMS envelope-encryption key on the EKS control plane. The modules'
outputs do leave it: Omnistrate reads every output to render the application
charts, including the sensitive ones in `terraform-omnistrate-aws/outputs.tf`
(declared `exported: false`, so not shown as instance outputs, but they pass
through Omnistrate).

## What each stage creates

### Stage 1: `pavo-bootstrap-aws/`

- **IAM:** the `pavo-permission-boundary-shared` policy
  (`policy-statements.json`), which caps every role stage 2 creates except
  the two MicroVM image roles ([permissions.md](permissions.md)); the
  External Secrets Operator (ESO) role (see `permissions.md`).
- **EKS access:** an access entry giving the Omnistrate runner role
  `AmazonEKSClusterAdminPolicy` on this cluster only.
- **Cluster add-ons (Helm):** External Secrets Operator, Stakater Reloader, the
  Sigstore policy controller, and optionally the ECK operator
  (`enable_eck`) and an in-VPC observability stack (`enable_observability`).
- **Kubernetes objects:** the `pd-balanced` storage class (plus `gp3-cmk`,
  backed by the cell key, with `enable_observability`), the
  `pavo-nginx` ingress class, the Let's Encrypt and self-signed cluster
  issuers, and the image-signature policies.
- **Networking:** S3 and DynamoDB gateway endpoints, only for route tables the
  existing endpoints don't already cover. Interface VPC endpoints for the AWS
  APIs the instance apply refreshes on plan (table in
  `pavo-bootstrap-aws/RUNBOOKS.md`) so a no-NAT cell can plan. Helm and
  in-VPC observability images are pinned from `mirrored-images.json`
  (artifact-plane ECR). That registry is in us-east-2; Omnistrate adds
  cross-region ECR and S3 interface endpoints and private zones to your VPC,
  so the cell may be in another region. Terraform providers and the Temporal
  chart come from a same-region bucket that exists for us-east-1 and
  us-east-2; another region needs Pavo to add it first.
- **Other:** SSM parameters under `/pavo/shared/` and `/pavo/cells/<cluster>/`,
  including a one-cell-per-account guard.

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
  endpoints; interface endpoints for the AWS APIs the instance uses (list in
  `network-and-egress.md`); and, with
  `network_posture = "strict"`, default-deny egress NetworkPolicies.
- **Kubernetes:** the instance namespace, ExternalSecrets that sync the
  database password, and configuration Secrets and ConfigMaps.
- **Optional components** (by `es_mode`, `temporal_mode`, `zitadel_mode`,
  `grafana_mode`): Elasticsearch either on Elastic Cloud or in-cluster (ECK);
  Temporal either on Temporal Cloud or in-cluster; Zitadel either Pavo's
  hosted service or in-cluster. Telemetry goes to Grafana Cloud by default
  (`grafana_mode = cloud`); `self_hosted` keeps it in-VPC (it needs
  `enable_observability` on the cell), and strict requires `grafana_mode = self_hosted`
  at instance creation; the plan fails otherwise.

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
| `network_posture` | `standard`, `strict` | Strict adds default-deny egress NetworkPolicies, an internal load balancer and an ACM certificate (`pavo-cert-aws/`) |
| `es_mode` | `cloud`, `self_hosted` | Elastic Cloud deployment, or an in-cluster ECK cluster with S3 snapshots |
| `grafana_mode` | `cloud` (default), `self_hosted` | Telemetry egress to Grafana Cloud, or in-VPC Prometheus/Grafana (strict requires `grafana_mode = self_hosted` at instance creation; the plan fails otherwise) |
| `temporal_mode` | `cloud`, `self_hosted` | Temporal Cloud, or an in-cluster Temporal with its own RDS |
| `zitadel_mode` | `cloud`, `self_hosted` | Pavo's hosted identity, or an in-cluster Zitadel configured by the stage 3 Job |

## Teardown

Deleting an instance destroys its stage 2 resources, subject to the
teardown controls in `terraform-omnistrate-aws/README.md` ("Teardown
contract"), for example RDS deletion protection and final snapshots. Stage 1
resources stay until you destroy that module; the SSM one-cell guard and the
MicroVM image resources have `prevent_destroy` set.
