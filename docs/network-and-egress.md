# Network and egress

## Inside your VPC

- **Data stores** (RDS, Redis, EFS) sit in private subnets behind their own
  security groups. RDS is not publicly accessible.
- **AWS APIs over PrivateLink:** with `enable_vpc_endpoints = true` (the
  default), stage 2 creates interface endpoints for Bedrock runtime, KMS,
  Secrets Manager, ECR (API and registry), SQS, SNS and STS, plus SES when
  email is enabled (`terraform-omnistrate-aws/vpc_endpoints.tf`). Calls to
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
| `ghcr.io` | Pavo container images and their signatures | always |
| Sigstore (`fulcio.sigstore.dev`, Rekor) | Signature verification at admission | always |
| Public Helm chart repositories | Add-on charts at install and upgrade time: External Secrets, Stakater, Sigstore, Elastic, Temporal, and the Prometheus, Grafana and OpenTelemetry charts | stage 1 and 2 applies |
| Terraform registry | Provider downloads by the Omnistrate runner | standard posture only |
| Let's Encrypt | Public TLS certificates for the ingress | always in standard |
| Elastic Cloud | Search, when `es_mode = "cloud"` | `es_mode` |
| Grafana Cloud | Metrics and dashboards, only when `grafana_mode = "cloud"` (BYOC default is `self_hosted`, which stays in-VPC) | `grafana_mode` |
| Temporal Cloud | Workflow engine, when `temporal_mode = "cloud"` | `temporal_mode` |
| Pavo identity service (`auth.pavoai.com`) | Sign-in, when `zitadel_mode = "cloud"` | `zitadel_mode` |
| Pavo alert endpoint | Forwarding of sanitised alert metadata | `pavo_app_alerts_enabled` (stage 1) |
| Your alert webhook | Alerts to your own channel | `customer_alert_webhook_url` (stage 1) |
| HubSpot | Contact sync on sign-up and login | `hubspot_enabled` (off by default) |
| Langfuse | LLM tracing: exports prompts and completions | `langfuse_enabled` (off by default) |
| E2B sandboxes, Google Cloud Storage | Sandboxes mount a data bucket with gcsfuse | `sandbox_gcsfuse_enabled` (off by default) |

The application may also call third-party APIs whose credentials stage 2
passes through, listed as Pavo-managed secrets in
[inputs-contract.md](inputs-contract.md). Whether it does depends on the
product features enabled for your instance.

### `strict`

Stage 2 adds a default-deny egress NetworkPolicy to the instance's workload
namespace (`terraform-omnistrate-aws/network_policies.tf`). Pods in that
namespace can reach only in-VPC destinations: the data stores, the interface
endpoints, S3 through the gateway endpoint, and the Kubernetes API. The
internet and the instance metadata service are denied.

- **Scope:** the policy covers the instance namespace only, not the whole
  cell. Platform namespaces (for example `kube-system`, `external-secrets`,
  `cosign-system`) keep their own rules.
- **Load balancer:** internal, not internet-facing, with certificates from the
  cell's private CA instead of Let's Encrypt.
- **Terraform providers:** the Omnistrate runner installs them only from the
  cell's in-account S3 mirror, over the gateway endpoint.
- **Prerequisites:** a strict instance fails at plan time unless the cell has
  the private CA and NetworkPolicy enforcement ready
  (`/pavo/cells/<cluster>/private_ca_ready` and `network_policy_ready`).
- **Not covered yet:** the public DNS record isn't suppressed in all
  configurations; see the `network_posture` description in
  `terraform-omnistrate-aws/variables.tf`.

## Inbound

Traffic enters through the `pavo-nginx` ingress class. With `standard`
posture the load balancer is internet-facing and serves Let's Encrypt
certificates; with `strict` it is internal.
