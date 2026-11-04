# Security

## Reporting a vulnerability

Please report security issues privately through GitHub: open the **Security**
tab of this repository and choose **Report a vulnerability**. Don't open a
public pull request; issues are disabled here.

Include the file and line, what an attacker could do, and any conditions it
depends on (for example `network_posture = "strict"` or self-hosted identity).

## Scope

In scope: anything in this repository, meaning the Terraform, templates,
policies and scripts Pavo uses to deploy into your AWS account, and how they
configure IAM, networking, encryption, secrets and image admission.

Out of scope here: Pavo's application code and hosted services. Report those
through your Pavo contact.

## Verifying Pavo images

Every Pavo-built `ghcr.io/pavoai/*` image the modules deploy is signed with Sigstore
cosign (keyless), with SBOM and vulnerability attestations on the same digest.
Admission checks the signature only on pulls by `ghcr.io` name. Every cell
pulls the same digests from Pavo's ECR mirror, and admission does not check
those names today; the control there is the digest pin. See [docs/permissions.md](docs/permissions.md#image-admission) for the
policy and how to verify an image yourself.
