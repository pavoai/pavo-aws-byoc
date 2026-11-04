# Network and egress

## Inside your VPC

- **Data stores** (RDS, Redis, EFS) sit in private subnets behind their own
  security groups. RDS is not publicly accessible.
- **AWS APIs over PrivateLink, by stage.** Stage 1 creates the cell's
  interface endpoints for KMS, Secrets Manager, IAM, RDS, ElastiCache, SNS,
  SQS, EFS, SES (`email`) and ACM, plus SageMaker API when
  `enable_sagemaker_api_endpoint` is set
  (`pavo-bootstrap-aws/vpc_interface_endpoints.tf`), and on a strict cell the
  Route 53 endpoint (`vpc_interface_endpoint_route53.tf`). Stage 2, with
  `enable_vpc_endpoints = true` (the default), lists Bedrock (runtime and
  control plane), KMS, Secrets Manager, ECR (API and registry), SQS, SNS, STS,
  RDS, EFS, ElastiCache and IAM, plus ACM on strict and SES when email is
  enabled, and creates only the services no existing private-DNS endpoint in
  the VPC already serves; on a bootstrapped cell that leaves at most the Bedrock,
  ECR and STS endpoints to stage 2 (`terraform-omnistrate-aws/vpc_endpoints.tf`).
  Calls to those services, including Bedrock prompts and embeddings, stay on
  the AWS network.
- **S3 and DynamoDB** go through gateway endpoints. Omnistrate's cell usually
  provides them; stage 1 fills any route tables they don't cover
  (`pavo-bootstrap-aws/vpc_gateway_endpoints.tf`).

## Egress by posture

Two settings carry the posture, and a strict deployment sets both:

- **Cell posture** (stage 1): `scripts/run-bootstrap.sh ... --strict` sets the
  module variable `network_posture = "strict"` and, after checking that the
  cell's VPC CNI add-on reports NetworkPolicy enforcement, `network_policy_ready
  = true`. The cell posture selects the strict permission boundary
  (`rendered-permission-boundary-strict.json`), creates the Route 53 interface
  endpoint, switches the Grafana ingress issuer to `pavo-selfsigned`, and
  publishes `/pavo/cells/<cluster>/network_policy_ready`, the parameter a strict
  instance checks at plan time.
- **Instance posture** (stage 2): the instance parameter `network_posture`. On
  `strict` it creates the default-deny egress NetworkPolicy below, makes the
  load balancer internal with the ACM certificate from `pavo-cert-aws/`, adds
  the ACM interface endpoint, applies the strict Helm profile, and fails the
  plan unless the four hosting modes are `self_hosted` and
  `redis_security_phase = enforced` at creation (`strict_profile.tf`).

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

The complete list of external services the application and the modules can
reach, with each one's default and its behaviour on strict, is the table in
[data-handled.md](data-handled.md#what-leaves-your-account); the credentials
stage 2 passes through are the Pavo-managed secrets in
[inputs-contract.md](inputs-contract.md).

### `strict`

Stage 2 adds one egress NetworkPolicy, `pavo-strict-egress`, to the instance
namespace: it selects every pod, has `policyTypes: [Egress]`, and allows
exactly the destinations below, so everything else is denied
(`terraform-omnistrate-aws/network_policies.tf`). The allow-list as the code
builds it:

- every CIDR of the VPC, primary and secondary associations, on all ports and
  protocols. This is what reaches the data stores and the interface endpoints;
  under the VPC CNI pod addresses come from the same subnets, so same-namespace
  pod-to-pod traffic and DNS (CoreDNS) are covered by this rule too;
- the AWS-managed S3 prefix list for the region, on all ports and protocols:
  the destination the S3 gateway endpoint routes to. DynamoDB is not listed;
- the cluster's Kubernetes service CIDR, on all ports and protocols, which is
  how pods reach the Kubernetes API;
- one rule per entry of the cell parameter
  `strict_egress_extra_destinations`, opening only that CIDR and only its
  listed TCP ports (your outbound proxy or an on-premises range; routing to it
  stays your network).

The internet and the instance metadata address are outside every rule. The
policy is enforced only when the cell's VPC CNI NetworkPolicy enforcement is
on; a strict instance fails at plan time unless the cell has published
`network_policy_ready`. Nothing in stage 2 restricts egress at the
security-group level: the data-store security groups allow all outbound
traffic, so this policy is the egress control.

- **S3 reach:** the gateway endpoints (Omnistrate's and stage 1's) carry the
  AWS default policy, so a pod allowed to S3 can reach any bucket through
  them; the IAM roles, not the endpoint, bound which buckets it may use.
- **Scope:** the policy covers the instance namespace only, not the whole
  cell. Platform namespaces (`kube-system`, `cert-manager`,
  `external-secrets`, `cosign-system`, `elastic-system`,
  `pavo-observability`) are outside it; the stage 1 observability namespace
  carries its own policies, the others are platform exceptions. Those namespaces are
  outside this policy, but on a private cell (no NAT) they have no internet
  route either: the signature admission controller cannot reach Sigstore or
  `ghcr.io`, and the alert forwarder reaches only what its own policy leg and
  your routing allow.
- **Load balancer:** internal, not internet-facing, with an ACM certificate
  requested by `pavo-cert-aws/` instead of Let's Encrypt.
- **Operator consoles:** Kibana, the Temporal UI and Grafana sit on that
  internal load balancer behind a generated password (Elasticsearch native
  user, nginx basic auth, Grafana admin). There is no SSO in front of them;
  reaching them needs VPC or Client VPN access plus the password.
- **Helm profile:** on strict the `aws-strict-profile` layers override stored
  portal values on every render: the API gateway runs with HubSpot and
  Langfuse off and the Brevo, HubSpot and Langfuse keys empty; the worker runs
  Bedrock-only (`llmCloudOnly`, Bedrock Titan embeddings) with Slack
  notifications off, the `pavo_custom` computer backend, and the OpenAI,
  Bedrock bearer, E2B, MicroVM, Slack, Parallel, Amplitude, Sumble, Gemini and
  Modal keys empty and the sandbox GCS mount disabled; onboarding runs
  Bedrock embeddings with the OpenAI, Bedrock bearer and Langfuse keys empty,
  and the knowledge service with the OpenAI and Bedrock bearer keys empty (`spec/spec-byoc.yaml`, the four `aws-strict-profile`
  blocks). `strict_profile.tf` requires ES, Grafana, Temporal and Zitadel to be
  self-hosted at creation and fails the plan otherwise, instead of migrating
  data.
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
