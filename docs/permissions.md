# Permissions

## Principals

| Principal | Created by | What it can do | Where to read it |
|---|---|---|---|
| Omnistrate runner role | Omnistrate, when you connect the account | Applies stage 2. Stage 1 gives it cluster-admin on this EKS cluster only (`AmazonEKSClusterAdminPolicy`, cluster scope) | `pavo-bootstrap-aws/main.tf` (`aws_eks_access_entry.runner`) |
| External Secrets role (cell) | Stage 1 | Installs the ESO controller. **Denies** Secrets Manager / KMS reads unless `legacy_eso_cell_secret_read = true` | `pavo-bootstrap-aws/main.tf` |
| External Secrets role (instance) | Stage 2 | Reads only this instance's RDS master secret(s) and decrypts via Secrets Manager on the cell key. Namespaced SecretStore `pavo-aws-sm` | `terraform-omnistrate-aws/main.tf` (`aws_iam_role.eso`) |
| Workload role (IRSA) | Stage 2 | What the application pods need: Bedrock, the instance's S3 buckets, SES, SNS and SQS. No `rds-db:connect` and no `elasticache:Connect` | `terraform-omnistrate-aws/main.tf` (`pavo_permissions`) |
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
  creates namespaced objects and some cluster-scoped ones (storage classes).
  SecretStores are namespaced (`pavo-aws-sm`), not cluster-wide.
- With self-hosted identity, the provisioner Job runs under its own service
  account with a Role and RoleBinding limited to the instance namespace
  (`terraform-omnistrate-aws/zitadel_provision.tf`).

## Image admission

Stage 1 installs the Sigstore policy controller and one `ClusterImagePolicy`
per Pavo service (`pavo-bootstrap-aws/main.tf`). The globs are
`ghcr.io/pavoai/<svc>*`. A matching image must be signed keyless by
`cloud-build-<service>@<central_ci_project_id>.iam.gserviceaccount.com`
(issuer `https://accounts.google.com`). The shared
`cloud-build@<central_ci_project_id>` identity is still accepted during
transition.

A private cell pulls artifact-plane ECR names
(`omnistrate/images/pavo/ghcr.io/pavoai/...`), which **do not match** those
globs. `no-match-policy = allow`, so admission does **not** signature-check
the image the pod starts. Integrity there is digest pin + copy. Plan: add CIP
globs for the ECR names before claiming enforce on this cell.

Non-Pavo images (ESO, ECK, Reloader, Prometheus, …) are the same ECR copy with
no CIP; one-time verify as agreed.

To verify an image yourself:

```bash
cosign verify ghcr.io/pavoai/<service>@sha256:<digest> \
  --certificate-oidc-issuer https://accounts.google.com \
  --certificate-identity cloud-build-<service>@<central_ci_project_id>.iam.gserviceaccount.com
```

The default `central_ci_project_id` is in `pavo-bootstrap-aws/variables.tf`.
