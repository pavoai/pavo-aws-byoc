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

Reply we sent on the BYOC security review, mapped to this branch (CMK path):
[`docs/security-review-response.md`](../docs/security-review-response.md).

## Bootstrap prerequisites

Two operator-applied modules must run before this one for a given customer +
cell, in this order:

1. **`pavo-customer-bootstrap/` once per customer** (Pavo-applied, GCS state).
   Creates all Zitadel resources and emits 15 identity runtime values that
   Pavo ops captures and passes through to this module as instance-create
   `apiParameters`. That module is not in this review copy.

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
- Encryption at rest: RDS, Redis, SNS, EFS, app S3 (`onboarding`, `data`), SQS, self-hosted ES snapshots, and Zitadel state use the cell CMK on **new** resources. Existing Redis / SNS / EFS keep their previous key (`lifecycle.ignore_changes`; EFS key change is ForceNew). App S3 encryption applies to **new objects**; existing objects stay SSE-S3 until rewritten. Node EBS default / keyless gp3 is the cell CMK (stage 1). The provider-mirror bucket stays SSE-S3.
- `network_posture = strict` is the umbrella: Helm `aws-strict-profile` layers override stored portal `$var` (Bedrock-only LLM, empty SaaS/MicroVM keys). OpenTofu `effective_*` in `strict_profile.tf` forces self-hosted ES / Grafana / Temporal / Zitadel.
- `aws_iam_role.eso` + `kubernetes_service_account_v1.eso` + `kubectl_manifest.{eso_secret_store,external_secret_db_credentials}` — per-instance IRSA role `pavo-eso-<instance_id>` (reads only this instance's RDS master secret(s), decrypts via Secrets Manager on the cell CMK), the `pavo-eso` ServiceAccount it trusts, a namespaced `SecretStore` `pavo-aws-sm` using that ServiceAccount, and the ExternalSecret that syncs the RDS master password into a K8s Secret apps consume via `secretKeyRef`. No other namespace can use the store. The ESO controller / Helm release itself is owned by `pavo-bootstrap-aws` (cell-scoped). `external_secret_db_credentials` carries `lifecycle { ignore_changes = [yaml_body], replace_triggered_by = [aws_db_instance.postgres, kubectl_manifest.eso_secret_store.kind] }` — suppresses the alekc/kubectl SSA-normalization diff loop against ESO-controller-mutated fields, while still forcing replacement when RDS replaces or the store kind changes so the manifest stays in sync.
  Downgrading an instance past this version needs operator work on the Omnistrate-managed instance state: set `legacy_eso_cell_secret_read = true` and apply `pavo-bootstrap-aws`, downgrade the instance, then replace both ExternalSecrets (`-replace=kubectl_manifest.external_secret_db_credentials -replace='kubectl_manifest.temporal_rds_master_external_secret[0]'`, the latter only with self-hosted Temporal); old versions only re-create them on RDS replace.
- `time_sleep.wait_for_rds` — gates dependent resources until the RDS instance is ready. (The runner's EKS access entry + `time_sleep.wait_for_eks_access` moved to `pavo-bootstrap-aws`, created once per cell.)

### Data-store network scoping

The three data stores each sit behind their own security group. They are **not**
scoped the same way, and the difference is deliberate:

| Security group | Port | Ingress scoped to | Why |
|---|---|---|---|
| `aws_security_group.elasticache` | 6379 | **EKS cluster security group** | Until `redis_security_phase = enforced` plaintext or token-less clients are accepted, so this SG is the effective control |
| `aws_security_group.rds` | 5432 | VPC CIDR | Defence in depth — RDS authenticates with a Secrets Manager password |
| `aws_security_group.efs` | 2049 | **EKS cluster security group** | File system policy denies non-TLS mounts and mounts without an access point (access point pins uid/gid 1000, dir mode 700); with `efs_iam_auth_enforced`, only the EFS CSI driver role may mount (`iam` mount option) |

Redis and EFS are scoped to the cluster because, under BYOC, the VPC belongs to the
**customer**, so VPC-CIDR ingress meant every unrelated resource they run there
could reach them. Redis accepts plaintext unauthenticated connections until the AUTH
migration below completes; EFS accepts anonymous (TLS, access-point) mounts unless the
instance was created with `efs_iam_auth_enforced`.

**The Redis rule depends on Security Groups for Pods being OFF** (EFS does not:
mounts come from the host-network `efs-csi-node` pods, always on the node ENI). With `ENABLE_POD_ENI=false`
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
# a test cell today), but the reserved key is the one guaranteed by the service, so
# prefer it — a filter that matches nothing would make the empty-result check
# above pass while inspecting zero nodes.
```

Custom networking matters as well as pod ENIs: `AWS_VPC_K8S_CNI_CUSTOM_NETWORK_CFG=true`
places pods on ENIs built from `ENIConfig` rather than the node's own, which can
carry a different security group and break this rule the same way.

### Redis TLS + AUTH

TLS and the AUTH token are gated by the per-instance spec parameter
`redis_security_phase`. Tokens (`random_password.redis_auth`, 64 alphanumeric
chars) live in Secret `pavo-redis-auth` (keys `gateway`, `intern`, `onboarding`).
Charts follow the outputs `redis_tls` and `redis_auth_secret_name` via the spec's
`aws-values` layers and connect with
`rediss://:<token>@host:port?ssl_check_hostname=true` (redis-py < 6 skips the
hostname check otherwise). The check needs a DNS name: `*_redis_host_ip` outputs
are `primary_endpoint_address`, not IPs, despite the name.

AWS forbids skipping steps on an existing group (TLS `preferred` before
`required`; token `ROTATE` before `SET`; no token while TLS is `preferred`), so
existing instances step one `instance modify` at a time:

| Phase | TLS mode | Token | Pods |
|---|---|---|---|
| `off` (default) | off | none | `redis://` |
| `tls_preferred` | `preferred` | none | `rediss://` |
| `tls_required` | `required` | `ROTATE` (optional) | `rediss://` + token |
| `enforced` | `required` | `SET` (required) | `rediss://` + token |

Terraform applies before the charts roll, and each step accepts both the old and
new pods, so no step drops connections. Enabling TLS moves the primary endpoint to
`master.*`; the host outputs follow it. New instances are created with `enforced`
(`scripts/create-aws-instance.sh`). No rollback below `tls_required` once
`enforced`. No automatic rotation: rotate on demand with `ROTATE`, roll the pods,
then `SET`.

There is deliberately **no `elasticache:Connect` grant** in the workload IAM
policy. ElastiCache IAM authentication requires transit encryption *and* a user
whose `AuthenticationMode` is `iam`; the groups use an AUTH token instead, so the
action can never be signed. The same applies to `rds-db:connect`: `iam_database_authentication_enabled`
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
| **Customer** (one `customer_name`) | `pavo-customer-bootstrap/` | Pavo ops (Zitadel PAT) | GCS `gs://pavo-terraform-state`, prefix `customer-bootstrap/<customer>` | Zitadel org, project, OIDC app, IdPs, login policy |
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
- Exception: the per-instance file-system StorageClass. Kubernetes has no namespaced StorageClass. AWS `efs-pavo-vpc-<instance_id>` must reference the instance's own EFS file system, which doesn't exist at bootstrap time; GCP `filestore-pavo-vpc-<instance_id>` has no cell-bootstrap module to live in.
- `pavo-customer-bootstrap/` MUST NOT declare `instance_id` as a variable (structural enforcement of the customer-hostname invariant).
- A second cell in the same AWS account is currently guarded by an SSM sentinel — see `pavo-bootstrap-aws/README.md`.
- No fifth "place": Omnistrate cell-amenities are not a home for Pavo infra. Cell-scoped infra a customer should apply/audit in their VPC → `pavo-bootstrap-aws/` (customer-applied), never an amenity (Pavo-applied, no audit trail). The observability stack shipped as an amenity by mistake — now migrated to `enable_observability` in `pavo-bootstrap-aws/` (the old `observability/` amenity module was removed).
