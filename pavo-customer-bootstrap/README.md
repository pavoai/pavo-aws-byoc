# pavo-customer-bootstrap

**Pavo-applied** (not customer-applied) Terraform module that provisions per-customer
identity resources in Pavo's shared Zitadel tenant (`auth.pavoai.com`). Runs **once
per customer** — before that customer's first Pavo instance can be created.

The customer never runs this module. They don't have Pavo's Zitadel PAT, and the
resources live in *Pavo's* identity infrastructure, not theirs. This module ships in
the same repo as `pavo-bootstrap-aws/` for code-locality and so the same module can be
reused across AWS BYOC, GCP BYOC, and any future cloud.

## Who runs this

- **Cloud identity (default):** Pavo operators, once per customer, against Pavo's
  shared Zitadel tenant. Nothing is created in the customer's AWS account. State
  is kept in a Pavo-owned GCS bucket, one prefix per customer.
- **Self-hosted identity (`zitadel_mode = self_hosted`):** a Kubernetes Job that
  `terraform-omnistrate-aws/zitadel_provision.tf` creates in the customer's
  cluster. It runs this module from the signed `zitadel-provisioner` image
  against the customer's in-VPC Zitadel, with state in a per-instance S3 bucket in
  the customer's account.

## What it creates

Per customer (one apply per `customer_name`):

- **1 Zitadel organization** (`zitadel_org.customer`) — name = `customer_name`. The
  org name is globally unique in Pavo's Zitadel tenant, which is the structural reason
  this module exists (a per-instance Zitadel org collided every time a test
  instance was re-created).
- **1 Zitadel project** (`zitadel_project.pavo`) — scoped to the org.
- **1 OIDC web application** (`zitadel_application_oidc.pavo_web`) — redirect URIs
  are `https://<customer_name>.<base_domain>/login/oidc-callback` and
  `http://localhost:3000/login/oidc-callback`. URIs depend on `customer_name` +
  `base_domain` only — **not** on instance ID. This is the customer-hostname
  invariant that justifies the module's scoping.
- **0-1 Identity providers** (`zitadel_org_idp_{google,oidc,saml}`) — conditionally
  created based on the `primary_external_identity_provider_*` inputs. A customer
  without an IdP configured (`automation_enabled = false`) gets just the org +
  project + OIDC app.
- **0-1 Login policy** (`zitadel_login_policy.primary_external_identity_provider`) —
  wired to the IdP(s) above. Default redirect URI: `https://<customer_name>.<base_domain>/login`.
- **0-1 SAML pre-fill action + trigger** (`zitadel_action.prefill_saml_register`,
  `zitadel_trigger_actions.prefill_saml_register`) — only created for SAML IdPs;
  populates user profile from SAML attribute statements so the registration form is
  skipped on first login.

## Outputs

**customer-bootstrap is the single source of truth for every identity value
pavoInfra needs to expose.** Pavo ops captures these and feeds them into
`terraform-omnistrate-aws` **and `terraform-omnistrate-gcp`** as instance-create
`apiParameters`. pavoInfra only passes them through on both clouds (the one
allowed transform is `base64encode` for the frontend's `_base64` outputs — a
pure function, no Zitadel knowledge).

GCP consumes **9** of these 15: it has no SAML customer, and `zitadel_project_id`
/ `zitadel_issuer` reach the GCP apps as top-level spec parameters rather than
through pavoInfra. See `terraform-omnistrate-gcp/README.md` → *Identity is a
pass-through*.

15 outputs total. Read with `tofu output -raw <name>`. `zitadel_oidc_client_secret`
is marked sensitive so it's redacted in `tofu output` (without `-raw`) and
in `tofu plan`.

### Core Zitadel (5)

| Output | Becomes pavoInfra var | Notes |
|---|---|---|
| `zitadel_org_id` | `var.zitadel_org_id` | |
| `zitadel_project_id` | `var.zitadel_project_id` | |
| `zitadel_oidc_client_id` | `var.zitadel_oidc_client_id` | |
| `zitadel_oidc_client_secret` (sensitive) | `var.zitadel_oidc_client_secret` | Omnistrate `type: Password` |
| `zitadel_issuer` | `var.zitadel_issuer` | |

### Identity runtime (10)

| Output | Becomes pavoInfra var | Notes |
|---|---|---|
| `zitadel_org_primary_domain` | `var.zitadel_org_primary_domain` | `<customer_name>.auth.pavoai.com` |
| `zitadel_idp_id` | `var.zitadel_idp_id` | OAuth IdP ID (google/oidc); empty for SAML / no-IdP. pavoInfra base64-encodes for frontend. |
| `primary_external_identity_provider_enabled` | `var.…_enabled` | Boolean. |
| `primary_external_identity_provider_type` | `var.…_type` | One of `""`, `google`, `okta`, `oidc`. |
| `primary_external_identity_provider_label` | `var.…_label` | "Continue with X" button text. |
| `primary_external_identity_provider_prompt` | `var.…_prompt` | OAuth `prompt` query param. |
| `primary_external_identity_provider_saml_idp_id` | `var.…_saml_idp_id` | SAML IdP ID; empty for non-SAML. |
| `primary_external_identity_provider_saml_sp_metadata_url` | `var.…_saml_sp_metadata_url` | Customer pastes into Okta SAML app. |
| `primary_external_identity_provider_saml_sp_entity_id` | `var.…_saml_sp_entity_id` | Identical to metadata URL today. |
| `primary_external_identity_provider_saml_acs_url` | `var.…_saml_acs_url` | Tenant-wide constant when SAML active. |

**Adding a new identity output?** Add it here, add a corresponding apiParameter
to `spec/spec-byoc.yaml` (both `pavoInfra` and `pavo-platform` service
blocks), add a `var` in `terraform-omnistrate-aws/variables.tf`, add a
pass-through `output` in `terraform-omnistrate-aws/outputs.tf`, and do the same
in `terraform-omnistrate-gcp/` if GCP needs to expose it. Update
`scripts/inject-zitadel-params.sh` and `scripts/create-aws-instance.sh` to wire
the new value through. The 15 lines in `inject-zitadel-params.sh`'s jq block
are the canonical handoff list — if you add to one without the other, the
operator-side migration will skip the value.

> Edit **`spec/spec-byoc.yaml`** only (never `spec-multitenant.yaml` — it's
> generated). After changing the spec, run `python3 scripts/render-multitenant-spec.py`
> and commit both specs, or `check-policy-drift` will fail. See the root README's
> "Two plans" section.

## Customer-hostname invariant

For a given `customer_name` + `base_domain`, Pavo exposes **one** customer-stable
auth hostname: `https://<customer_name>.<base_domain>`.

The Zitadel OIDC app is customer-scoped because its redirect URIs depend only on
`customer_name` and `base_domain`, **not** on `instance_id`. The module enforces
this structurally: `variables.tf` does NOT declare an `instance_id` variable. The
rule is "if you can't input it, you can't accidentally use it in a redirect URI." A
CI grep (lands in PR 2) confirms no `.tf` file in this module references
`instance_id` or `var.instance_id`.

If we ever introduce per-instance hostnames, multiple concurrent public instances per
`customer_name`, or per-cell customer hostnames, this invariant breaks and the OIDC
app's scoping must be redesigned (back to per-instance, or to a shared app with a
list of per-instance redirect URIs — both with non-trivial design cost).

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
