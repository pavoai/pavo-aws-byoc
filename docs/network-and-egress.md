# Network and egress

## Inside your VPC

- **Data stores** (RDS, Redis, EFS) sit in private subnets behind their own
  security groups. RDS is not publicly accessible.
- **AWS APIs over PrivateLink:** with `enable_vpc_endpoints = true` (the
  default), stage 2 creates interface endpoints for Bedrock (runtime and
  control plane), KMS, Secrets Manager, ECR (API and registry), SQS, SNS, STS,
  RDS, EFS, ElastiCache and IAM, plus ACM on strict and SES when email is enabled
  (`terraform-omnistrate-aws/vpc_endpoints.tf`). Calls to
  those services, including Bedrock prompts and embeddings, stay on the AWS
  network.
- **S3 and DynamoDB** go through gateway endpoints. Omnistrate's cell usually
  provides them; stage 1 fills any route tables they don't cover
  (`pavo-bootstrap-aws/vpc_gateway_endpoints.tf`).

## Egress by posture

`network_posture` is set per instance.

### `standard`

Pods can reach the internet through your NAT gateway. The deployment contacts:

| Destination | Why | Controlled by |
|---|---|---|
| Artifact-plane ECR (same digest as `ghcr.io/pavoai/*`) | Runtime image pull. Cloud Build still signs at GHCR; Pavo's artifact-plane publish copies the digest | always |
| `ghcr.io` | Cosign signatures exist here. CIP globs match these names; pods on every posture pull ECR names instead, so admission does not check those pulls today | always (signatures); CIP match is GHCR-only |
| Sigstore (`fulcio.sigstore.dev`, Rekor) | Signature verification at admission | always |
| Public Helm chart repositories | Stage 1 add-on chart tarballs; their images come from the artifact-plane mirror (`mirrored-images.json`) | stage 1 apply, from the machine running it |
| Pavo's S3 chart bucket (`pavo-tf-provider-mirror-<pavo-account>-<region>`) | Self-hosted Temporal chart (`terraform-omnistrate-aws/temporal_self_hosted.tf`) | `temporal_mode = "self_hosted"` |
| Pavo's artifact-plane S3 provider mirror | Provider downloads by the Omnistrate runner | always |
| Let's Encrypt | Public TLS certificates for the ingress | always in standard |
| Elastic Cloud | Search, when `es_mode = "cloud"` | `es_mode` |
| Grafana Cloud | Metrics and dashboards, when `grafana_mode = "cloud"` (the default in standard posture; `self_hosted` stays in-VPC). strict requires `grafana_mode = self_hosted` at instance creation; the plan fails otherwise | `grafana_mode` |
| Temporal Cloud | Workflow engine, when `temporal_mode = "cloud"` | `temporal_mode` |
| Pavo identity service (`auth.pavoai.com`) | Sign-in, when `zitadel_mode = "cloud"` | `zitadel_mode` |
| Pavo alert endpoint | Forwarding of sanitised alert metadata | `pavo_app_alerts_enabled` (stage 1) |
| Your alert webhook | Alerts to your own channel | `customer_alert_webhook_url` (stage 1) |
| HubSpot | Contact sync on sign-up and login | `hubspot_enabled` (off by default) |
| Langfuse | LLM tracing: exports prompts and completions | `langfuse_enabled` (off by default) |
| E2B sandboxes | Sandbox-backed agent sessions | `e2b_api_key` (empty by default) |
| Google Cloud Storage | Sandboxes mount a data bucket with gcsfuse | `sandbox_gcsfuse_enabled` (off by default) |

The application may also call third-party APIs whose credentials stage 2
passes through, listed as Pavo-managed secrets in
[inputs-contract.md](inputs-contract.md). Whether it does depends on the
product features enabled for your instance.

### `strict`

Stage 2 adds a default-deny egress NetworkPolicy to the instance's workload
namespace (`terraform-omnistrate-aws/network_policies.tf`). Pods in that
namespace can reach only in-VPC destinations: the data stores, the interface
endpoints, S3 through the gateway endpoint, and the Kubernetes API, plus any
`strict_egress_extra_destinations` the cell publishes (your own network
ranges and ports, set in stage 1). The internet and the instance metadata
service are denied.

- **S3 reach:** the gateway endpoints (Omnistrate's and stage 1's) carry the
  AWS default policy, so a pod allowed to S3 can reach any bucket through
  them; the IAM roles, not the endpoint, bound which buckets it may use.
- **Scope:** the policy covers the instance namespace only, not the whole
  cell. Platform namespaces (for example `kube-system`, `external-secrets`,
  `cosign-system`) keep their own rules.
- **Load balancer:** internal, not internet-facing, with an ACM certificate
  requested by `pavo-cert-aws/` instead of Let's Encrypt.
- **Operator consoles:** Kibana, the Temporal UI and Grafana sit on that
  internal load balancer behind a generated password (Elasticsearch native
  user, nginx basic auth, Grafana admin). There is no SSO in front of them;
  reaching them needs VPC or Client VPN access plus the password.
- **Umbrella:** `network_posture = "strict"` is the single control. Helm
  `aws-strict-profile` layers override stored portal values on every render
  (Bedrock-only LLM, empty OpenAI / Langfuse / HubSpot / MicroVM keys).
  `strict_profile.tf` pins ES / Grafana / Temporal / Zitadel to self-hosted;
  `strict_hosting_guard` fails the plan if any of the four is set to `cloud`,
  instead of migrating data.
- **Prerequisites:** a strict instance fails at plan time unless the cell has
  NetworkPolicy enforcement ready (`/pavo/cells/<cluster>/network_policy_ready`)
  and the instance was created with `es_mode`, `grafana_mode`, `temporal_mode`,
  `zitadel_mode` = `self_hosted` and `redis_security_phase = enforced`
  (`strict_profile.tf`).
- **Images:** nodes pull from artifact-plane ECR over PrivateLink. CIP globs
  are still `ghcr.io/pavoai/<svc>*`; those ECR names do not match, and
  `no-match-policy = allow`, so admission does not signature-check the pull.
  Digest pin + copy is the integrity control until CIP globs include the ECR
  names. Non-Pavo images (ESO, ECK, Reloader, …) are the same ECR copy with
  no CIP.
- **Not covered:** the public DNS record is still published; it points at the
  internal LB. See the `network_posture` description in
  `terraform-omnistrate-aws/variables.tf`.

## Inbound

Traffic enters through the `pavo-nginx` ingress class. With `standard`
posture the load balancer is internet-facing and serves Let's Encrypt
certificates; with `strict` it is internal and serves an ACM certificate.
