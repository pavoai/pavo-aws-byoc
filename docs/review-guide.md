# Review guide

## Suggested order

1. [architecture.md](architecture.md): the stages and who runs what.
2. [permissions.md](permissions.md): IAM, the permission boundary, RBAC and
   image admission.
3. [network-and-egress.md](network-and-egress.md): what your VPC talks to.
4. [data-handled.md](data-handled.md): encryption and secrets.
5. [inputs-contract.md](inputs-contract.md): every input and its source.
6. The code, starting from each module's `main.tf`, `variables.tf` and
   `README.md`.

## Checklist

- [ ] Every IAM role stage 2 creates carries the stage 1 permission boundary.
- [ ] No policy grants access to resources outside the instance, except where
      the reason is documented.
- [ ] Data stores holding customer data are encrypted at rest, and you accept
      the key choice for each ([data-handled.md](data-handled.md)).
- [ ] The egress for your chosen modes matches your policy.
- [ ] Images are admission-controlled in `enforce` mode.
- [ ] You accept the state locations and what they contain.
- [ ] You accept the teardown behaviour (`terraform-omnistrate-aws/README.md`,
      "Teardown contract").

## Comparing snapshots

Each publish is one commit on `main`. Find the one you last reviewed, then:

```bash
git diff <reviewed-commit> main -- terraform-omnistrate-aws/
```

`PROVENANCE.json` in each snapshot names the private commit it came from and
the SHA-256 of every file.

## Recomputing a module hash

```bash
jq -r --arg m pavo-bootstrap-aws \
  '.files | to_entries[] | select(.key | startswith($m + "/")) | "\(.key) \(.value | ltrimstr("sha256:"))"' \
  PROVENANCE.json | LC_ALL=C sort | sha256sum
```

The result should equal `.modules["pavo-bootstrap-aws"].tree_sha256`. To check
a single file, compare `sha256sum <file>` with its entry under `files`.

## What this repository does and doesn't guarantee

Every Terraform, template, policy and script file here is byte-for-byte the file
in Pavo's private repository at the snapshot's commit, except
`terraform-omnistrate-aws/customer-configuration.tf`, which is a marked
stand-in (listed under `generated` in `PROVENANCE.json`).

This copy is not signed, and nothing ties a running deployment to it.
Omnistrate applies `terraform-omnistrate-aws` from Pavo's private repository
at apply time, you apply `pavo-bootstrap-aws` from the version you pin, and
self-hosted identity runs from a separately built image. Ask your Pavo
contact which commit an instance was applied from.
