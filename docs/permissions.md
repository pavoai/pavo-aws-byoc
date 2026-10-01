# Permissions

## Principals

| Principal | Created by | What it can do | Where to read it |
|---|---|---|---|
| Omnistrate runner role | Omnistrate, when you connect the account | Applies stage 2. Stage 1 gives it cluster-admin on this EKS cluster only (`AmazonEKSClusterAdminPolicy`, cluster scope) | `pavo-bootstrap-aws/main.tf` (`aws_eks_access_entry.runner`) |
| External Secrets role | Stage 1 | Reads the secrets ESO syncs, and decrypts with the cell key | `pavo-bootstrap-aws/main.tf` (`pavo_eso_permissions`) |
| Workload role (IRSA) | Stage 2 | What the application pods need: Bedrock, RDS IAM auth, the instance's S3 buckets, SES, SNS and SQS | `terraform-omnistrate-aws/main.tf` (`pavo_permissions`) |
| KEDA role | Stage 2 | Reads SQS queue attributes to scale workers | `terraform-omnistrate-aws/main.tf` (`keda_sqs`) |
| Elasticsearch snapshot role | Stage 2, `es_mode = "self_hosted"` | Reads and writes the snapshot bucket, with the cell key | `terraform-omnistrate-aws/elasticsearch_snapshots.tf` |
| Identity provisioner role | Stage 2, `zitadel_mode = "self_hosted"` | Reads and writes its state bucket, with the cell key | `terraform-omnistrate-aws/zitadel_provision.tf` |

## The permission boundary

Stage 1 creates `pavo-permission-boundary-shared` from
`pavo-bootstrap-aws/policy-statements.json` (rendered as
`rendered-permission-boundary.json`). Every role stage 2 creates sets it as
its permissions boundary, so a role's effective permissions are the
intersection of its own policy and the boundary. A mistake in a stage 2
policy can't grant more than the boundary allows.

`pavo-bootstrap-aws/RUNBOOKS.md` ("Permission boundary scoping &
verification") explains each statement and how to check an edit.

## Kubernetes RBAC

- The runner gets cluster-admin through the EKS access entry, because stage 2
  creates namespaced objects and some cluster-scoped ones (storage classes,
  the External Secrets cluster store).
- With self-hosted identity, the provisioner Job runs under its own service
  account with a Role and RoleBinding limited to the instance namespace
  (`terraform-omnistrate-aws/zitadel_provision.tf`).

## Image admission

Stage 1 installs the Sigstore policy controller and one `ClusterImagePolicy`
per Pavo service (`pavo-bootstrap-aws/main.tf`). Images from
`ghcr.io/pavoai/**` must be signed keyless by the service's build identity,
`cloud-build-<service>@<central_ci_project_id>.iam.gserviceaccount.com`,
issued by `https://accounts.google.com`. During a transition period the shared
build identity `cloud-build@<central_ci_project_id>.iam.gserviceaccount.com` is
also accepted (see the comments in `pavo-bootstrap-aws/main.tf`).
`image_policy_mode` defaults to `enforce`, which rejects unsigned or wrongly
signed images.

To verify an image yourself:

```bash
cosign verify ghcr.io/pavoai/<service>@sha256:<digest> \
  --certificate-oidc-issuer https://accounts.google.com \
  --certificate-identity cloud-build-<service>@<central_ci_project_id>.iam.gserviceaccount.com
```

The default `central_ci_project_id` is in `pavo-bootstrap-aws/variables.tf`.
