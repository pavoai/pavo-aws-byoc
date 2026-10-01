# terraform-omnistrate-aws

**Per-instance scope.** Omnistrate-applied Terraform module for AWS BYOC.
Provisions per-instance cloud resources (RDS, ElastiCache, S3, SNS/SQS, EFS,
workload IRSA role, per-instance K8s namespace + ExternalSecret + EFS
StorageClass, Elastic Cloud deployment) on top of:

- [`pavo-bootstrap-aws/`](../pavo-bootstrap-aws/README.md) — customer-applied
  cell-scope bootstrap (IAM boundaries, ESO/Reloader Helm, EKS access entry,
  IngressClass, ClusterIssuer).
- `pavo-customer-bootstrap/` — Pavo-applied customer-scope identity bootstrap
  (Zitadel org/project/OIDC app/IdPs/login policy, every identity runtime
  value this module exposes). Not included in the public review copy.

Runs inside the Omnistrate Terraform runner; state lives in Omnistrate.

## Bootstrap prerequisites

Two operator-applied modules must run before this one for a given customer +
cell, in this order:

1. **`pavo-customer-bootstrap/` once per customer** (Pavo-applied, GCS state).
   Creates all Zitadel resources and emits 15 identity runtime values that
   Pavo ops captures and passes through to this module as instance-create
   `apiParameters`. See `pavo-customer-bootstrap/README.md`.

2. **`pavo-bootstrap-aws/` once per cell** (customer-applied). Creates
   account-shared IAM boundaries, the cell-scoped EKS access entry (incl. the
   Omnistrate runner's cluster-admin access), ESO/Reloader Helm releases, EBS
   CSI IRSA, cluster-scoped K8s resources, and the `/pavo/shared/*` +
   `/pavo/cells/<eks_cluster_name>/*` SSM parameters.

   Of those, **this module reads only** `/pavo/shared/permission_boundary_arn`
   (account-scoped). The ESO-role and EBS-CSI-boundary params are consumed
   inside `pavo-bootstrap-aws` itself; this module receives cell metadata like
   `vpc_id` / `eks_cluster_name` as instance `apiParameters`, not via SSM.

Without (2), the apply fails with
`reading SSM Parameter (/pavo/shared/permission_boundary_arn): couldn't find resource`.
Without (1), the variable-validation precondition fires:
`primary_external_identity_provider_type is required when ... _enabled is true`.

## EKS auth

The kubernetes/kubectl/helm providers authenticate to EKS using **exec
credentials**: each provider runs `aws eks get-token` per Kubernetes API
request, which mints a short-lived token and refreshes it automatically. This
avoids the static-token TTL problem — a single `data.aws_eks_cluster_auth`
token is fetched once per Terraform evaluation, and a long apply (helm_release
with `wait=true` followed by an ExternalSecret `wait_for{Ready=True}` chain)
can outlast it and fail mid-stream with `Unauthorized`. See the
`locals.eks_exec_*` block in `providers.tf`.

This depends on the AWS CLI being present on the Omnistrate Terraform runner
image. Omnistrate added the AWS CLI to the runner image in 2026-05; before
that the module briefly vendored the `aws-iam-authenticator` binary, but the
runner stages only `.tf` files into the apply directory so a committed binary
never reached it.

### Omnistrate Terraform runner contract

| Dependency | Used by | Notes |
|---|---|---|
| `sh` (POSIX, at `/bin/sh`) | all `local-exec` provisioners | Provisioner interpreter. |
| `aws` (AWS CLI v2) | provider exec auth (`aws eks get-token`); `local-exec` for `bedrock_model_agreements` | Present in the Omnistrate runner image since 2026-05. |

The EKS access entry that grants the runner role cluster RBAC is created with
native AWS-provider resources (`aws_eks_access_entry` /
`aws_eks_access_policy_association`), which need no AWS CLI. It now lives in
`pavo-bootstrap-aws` (created once per cell), not in this module.

## Key resources

- `data.aws_ssm_parameter.permission_boundary_arn` — reads `/pavo/shared/permission_boundary_arn` from the bootstrap module's output (the ESO-role and EBS-CSI-boundary params are consumed inside `pavo-bootstrap-aws`, not here)
- `aws_iam_role.pavo` (app IRSA, with the bootstrap permission boundary attached) + `aws_iam_role.keda_sqs` (KEDA SQS-scaler IRSA). The EBS CSI driver (IRSA role, SA, RBAC) is owned by Omnistrate — neither this module nor `pavo-bootstrap-aws` manages it.
- `aws_db_instance.postgres` — RDS with `manage_master_user_password = true` (master password lives in customer Secrets Manager, encrypted with `var.cell_kms_key_arn`)
- Application S3 (`onboarding`, `intern_data`) and EFS use the same cell CMK. `kms_key_id` on EFS is ForceNew — changing it replaces the filesystem.
- All three SNS topics (`data_fetcher`, `dedup`, `connector_sync`) use `alias/aws/sns`, not the cell CMK.
- `kubectl_manifest.{eso_cluster_secret_store,external_secret_db_credentials}` — per-instance ClusterSecretStore + ExternalSecret that sync the RDS master password into a K8s Secret apps consume via `secretKeyRef`. The ESO controller / Helm release itself is owned by `pavo-bootstrap-aws` (cell-scoped). `external_secret_db_credentials` carries `lifecycle { ignore_changes = [yaml_body], replace_triggered_by = [aws_db_instance.postgres] }` — suppresses the alekc/kubectl SSA-normalization diff loop against ESO-controller-mutated fields, while still forcing replacement when RDS itself replaces so the manifest stays in sync.
- `time_sleep.wait_for_rds` — gates dependent resources until the RDS instance is ready. (The runner's EKS access entry + `time_sleep.wait_for_eks_access` moved to `pavo-bootstrap-aws`, created once per cell.)

### Data-store network scoping

The three data stores each sit behind their own security group. They are **not**
scoped the same way, and the difference is deliberate:

| Security group | Port | Ingress scoped to | Why |
|---|---|---|---|
| `aws_security_group.elasticache` | 6379 | **EKS cluster security group** | This SG is the *only* access control on Redis |
| `aws_security_group.rds` | 5432 | VPC CIDR | Defence in depth — RDS enforces TLS (`rds.force_ssl=1`) and authenticates with a Secrets Manager password |
| `aws_security_group.efs` | 2049 | VPC CIDR | Defence in depth — EFS is encrypted in transit (the CSI driver enables TLS by default) and authorises via IAM + POSIX |

Redis is scoped tightest because it has nothing else. The replication groups run
with `transit_encryption_enabled = false` and the account's `default` /
no-password user, so anything that can reach port 6379 can read and write the
gateway, intern and onboarding caches in plaintext. Under BYOC the VPC belongs to
the **customer**, so VPC-CIDR ingress meant every unrelated resource they run
there could reach it.

**This depends on Security Groups for Pods being OFF.** With `ENABLE_POD_ENI=false`
pods inherit the security groups on the node ENIs, so the cluster security group is
the correct handle for "traffic from an EKS pod". If that feature is ever enabled,
pod traffic moves to branch ENIs with their own security groups and this rule stops
matching. Re-scope it in the same change that enables it. To check a cell:

```bash
# 1. Security Groups for Pods must be OFF (pods must inherit node ENI SGs)
kubectl -n kube-system get ds aws-node -o jsonpath='\
{range .spec.template.spec.containers[0].env[*]}{.name}={.value}{"\n"}{end}' \
  | grep -E 'ENABLE_POD_ENI|AWS_VPC_K8S_CNI_CUSTOM_NETWORK_CFG'
# expect: ENABLE_POD_ENI=false and AWS_VPC_K8S_CNI_CUSTOM_NETWORK_CFG=false

# 2. No SecurityGroupPolicy objects (they would move pod traffic to branch ENIs)
kubectl get securitygrouppolicies -A
# expect: No resources found

# 3. EVERY running node carries the cluster security group, or the pods on any
#    node that does not will lose Redis access
CLUSTER=<eks_cluster_name>
SG=$(aws eks describe-cluster --name "$CLUSTER" \
      --query 'cluster.resourcesVpcConfig.clusterSecurityGroupId' --output text)
aws ec2 describe-instances \
  --filters "Name=tag:aws:eks:cluster-name,Values=$CLUSTER" \
            "Name=instance-state-name,Values=running" \
  --query "Reservations[].Instances[?!contains(SecurityGroups[].GroupId, '$SG')].InstanceId" \
  --output text
# expect: empty (no node is missing the cluster SG)
#
# aws:eks:cluster-name is the AWS-reserved tag the EKS service applies. Managed
# node groups also carry the unprefixed eks:cluster-name (both are present on
# Pavo's test cell today), but the reserved key is the one guaranteed by the service, so
# prefer it — a filter that matches nothing would make the empty-result check
# above pass while inspecting zero nodes.
```

Custom networking matters as well as pod ENIs: `AWS_VPC_K8S_CNI_CUSTOM_NETWORK_CFG=true`
places pods on ENIs built from `ENIConfig` rather than the node's own, which can
carry a different security group and break this rule the same way.

Narrowing the SG limits **who can reach** Redis; it does not authenticate them.
Any pod on the cluster still can, and the traffic is still plaintext. Real
authentication requires transit encryption plus an auth token, which is a staged
migration across this repo and the app charts:

```text
SG -> TLS preferred -> AUTH ROTATE -> apps to rediss:// + token -> AUTH SET -> TLS required
```

Every step except the app roll is infra-only, and each is individually reversible.
Do not attempt it in one change.

There is deliberately **no `elasticache:Connect` grant** in the workload IAM
policy. ElastiCache IAM authentication requires transit encryption *and* a user
whose `AuthenticationMode` is `iam`; with neither present the action can never be
signed. The same applies to `rds-db:connect`: `iam_database_authentication_enabled`
is not set on the RDS instance, and the apps authenticate with a password from
Secrets Manager. Re-add either grant only in the change that switches the
corresponding mechanism on.

## Teardown contract

To delete a Pavo instance running this module:

1. **Prepare the instance for destroy.** Set these inputs via Omnistrate instance modify
   (`omnistrate-ctl instance modify <id> --param '{...}'`), or one-off via direct AWS CLI:

   | Input | Why |
   |---|---|
   | `rds_deletion_protection = false` | Removes the AWS-native deletion-protection guard on the RDS instance. |
   | `force_destroy_buckets = true` *(only if buckets are non-empty)* | Tells Terraform to empty buckets during destroy. If you'd rather empty them yourself, leave this `false` and run `aws s3 rm s3://<bucket> --recursive` first. |
   | `create_final_snapshot = false` *(only for Dev/test recreate cycles)* | Skips the final RDS snapshot. Leave `true` for prod/customer instances. |

   Direct AWS CLI equivalent for RDS deletion-protection (if you can't or don't want to
   go through Omnistrate modify):

   ```bash
   aws rds modify-db-instance \
     --db-instance-identifier pavo-instance-<instance_id> \
     --no-deletion-protection \
     --apply-immediately

   aws rds wait db-instance-available \
     --db-instance-identifier pavo-instance-<instance_id>
   ```

2. **Delete the instance:**

   ```bash
   omnistrate-ctl instance delete <instance_id>
   ```

Terraform destroy will complete cleanly: ElastiCache groups, S3 buckets (if empty or
`force_destroy_buckets = true`), EFS, and the Elasticsearch deployment have no
`prevent_destroy` guard. **Data durability is handled by backups/snapshots, not
`prevent_destroy`** — RDS keeps a final snapshot when `create_final_snapshot = true`
(default), S3 keeps `force_destroy = false` by default (destroy errors loudly on
non-empty bucket), and Elastic Cloud takes its own snapshots on the configured policy.

No manual Elastic Cloud delete is needed — Terraform destroys `ec_deployment` and
`elasticstack_elasticsearch_security_api_key` in dependency order (key first, then
deployment). No `terraform state rm` is needed.

**Do not manually delete `ec_deployment` from the Elastic Cloud console** before
issuing destroy. The elasticstack provider sources its endpoint from `ec_deployment`
at init time; if the deployment is gone from state, refresh of the orphaned API key
fails with `Unable to get Elasticsearch client` and the destroy plan can't be
generated — recovery then requires Omnistrate engineer state surgery. With
`prevent_destroy` removed from `ec_deployment` (PR #112), there's no reason to do
this anyway: Terraform destroys it normally.

**Caveat:** instances whose `ec_deployment` was manually deleted out-of-band
*before* PR #112 landed are already in this drifted state and need one-time
Omnistrate state repair. This contract describes the clean future path.

## Ownership rules

Resources are scoped at one of four levels. The level determines which
module owns the resource, who applies it, and where state lives.

| Scope | Module | Applier | State backend | Examples |
|---|---|---|---|---|
| **Account** | `pavo-bootstrap-aws/` (AWS only) | Customer (AWS creds) | Customer-local | IAM permission boundaries, `/pavo/shared/*` SSM |
| **Cell** (one EKS cluster) | `pavo-bootstrap-aws/` (AWS only) | Customer (AWS creds) | Customer-local | IngressClass, ClusterIssuer, ESO/Reloader helm releases, EKS access entry, `/pavo/cells/<cluster>/*` SSM |
| **Customer** (one `customer_name`) | `pavo-customer-bootstrap/` | Pavo ops (Zitadel PAT) | Pavo-owned GCS bucket, prefix `customer-bootstrap/<customer>` | Zitadel org, project, OIDC app, IdPs, login policy |
| **Instance** (one Pavo deployment) | `terraform-omnistrate-aws/` (AWS)<br>`terraform-omnistrate-gcp/` (GCP) | Omnistrate runner | Omnistrate-managed | AWS: RDS, ElastiCache, S3, SNS/SQS, EFS, workload IAM role.<br>GCP: Cloud SQL, Memorystore, GCS, Pub/Sub, workload service account.<br>Both: per-instance namespace, app secrets, Elastic Cloud deployment |

Account and Cell scope are AWS-only today: GCP has no cell-bootstrap module, so a
GCP cell's substrate is not customer-applied. Customer scope is cloud-neutral —
`pavo-customer-bootstrap/` owns identity for both clouds.

### Picking the right module for a new resource

1. If deleting one Pavo instance shouldn't delete it → not the per-instance module (`terraform-omnistrate-aws/` or `terraform-omnistrate-gcp/`).
2. If its `name` doesn't include `var.instance_id` → probably not the per-instance module.
3. If it lives in Pavo's identity tenant (Zitadel) → `pavo-customer-bootstrap/`.
4. If it's cluster-scoped K8s or per-cell IAM → `pavo-bootstrap-aws/`.
5. Otherwise (per-instance app resource) → the per-instance module for that cloud.
6. If it's a self-hostable cell substrate the customer opts into (ECK, in-VPC observability) → `pavo-bootstrap-aws/` behind an `enable_*` flag — NEVER an Omnistrate cell-amenity. See `pavo-bootstrap-aws/README.md` → *Cell self-hosting flags*.

### Hard rules

- No cluster-scoped K8s resource may live in a per-instance module, even with `apply_only = true` as a mitigation.
- `pavo-customer-bootstrap/` MUST NOT declare `instance_id` as a variable (structural enforcement of the customer-hostname invariant).
- A second cell in the same AWS account is currently guarded by an SSM sentinel — see `pavo-bootstrap-aws/README.md`.
- No fifth "place": Omnistrate cell-amenities are not a home for Pavo infra. Cell-scoped infra a customer should apply/audit in their VPC → `pavo-bootstrap-aws/` (customer-applied), never an amenity (Pavo-applied, no audit trail). The observability stack shipped as an amenity by mistake — now migrated to `enable_observability` in `pavo-bootstrap-aws/` (the old `observability/` amenity module was removed).
