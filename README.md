# Pavo on AWS (BYOC): Terraform for security review

This repository is a **read-only copy** of the Terraform that Pavo uses to deploy
into your AWS account, published so your security team can review it. It is
generated from Pavo's private source repository. Nothing here is consumed
directly: it isn't used by the installer, by Omnistrate, or by any release.

- Snapshot of private commit `d9db7112d204`, published 2026-10-01T11:17:02Z.
- `PROVENANCE.json` lists the SHA-256 of every file and the commit it came from.
- Pull requests and issues aren't accepted here. To report a security issue,
  see [SECURITY.md](SECURITY.md).

## The two modules

| Module | Applied by | Files |
|---|---|---|
| [`pavo-bootstrap-aws/`](pavo-bootstrap-aws/) | customer | 34 |
| [`terraform-omnistrate-aws/`](terraform-omnistrate-aws/) | omnistrate | 17 |

A deployment runs them in this order:

1. **[`pavo-bootstrap-aws/`](pavo-bootstrap-aws/)** — you apply it once per
   deployment cell (one EKS cluster), with your own AWS credentials and state.
   It creates the account- and cell-level pieces: the IAM permission boundary,
   the External Secrets role, cluster add-ons, image-signature admission
   policies, and SSM parameters the next stage reads.
2. **[`terraform-omnistrate-aws/`](terraform-omnistrate-aws/)** — Omnistrate's
   runner applies it in your account for each Pavo instance. It creates the
   instance's data stores (RDS, ElastiCache, S3, EFS, SQS/SNS), its IAM roles,
   and its Kubernetes namespace and secrets.

Identity setup (Zitadel org, project, OIDC app, optional IdP) is applied by
Pavo, or by an in-cluster Job when you self-host Zitadel. That module is not
in this review copy.

Start with [docs/review-guide.md](docs/review-guide.md).

## Reviewer guides

- [docs/architecture.md](docs/architecture.md): the stages, credentials and state.
- [docs/permissions.md](docs/permissions.md): IAM, RBAC and image admission.
- [docs/network-and-egress.md](docs/network-and-egress.md): what your VPC talks to.
- [docs/data-handled.md](docs/data-handled.md): secrets and data, and where they live.
- [docs/inputs-contract.md](docs/inputs-contract.md): every input and where its value comes from.

<!-- guarantees-statement -->
## What this repository does and doesn't guarantee

Every Terraform, template, policy and script file here is byte-for-byte the file
in Pavo's private repository at the commit above. There is one exception:
`terraform-omnistrate-aws/customer-configuration.tf` is a stand-in. The real
file holds optional per-customer cost-allocation tags keyed by customer name;
the stand-in has the same shape with an empty map.

This copy is not signed, and nothing ties a running deployment to it:

- Omnistrate applies `terraform-omnistrate-aws` from Pavo's private repository
  at apply time, so an instance may have been applied from a commit before or
  after this snapshot.
- You apply `pavo-bootstrap-aws` from the `pavoai/pavo-bootstrap-aws`
  repository at the version you pin, which may differ from this snapshot.
- With self-hosted identity, the identity Job runs from the signed
  `zitadel-provisioner` image, which is built separately from this copy.

This repository has no licence. You may read it; it grants no right to reuse,
modify or redistribute its contents.
