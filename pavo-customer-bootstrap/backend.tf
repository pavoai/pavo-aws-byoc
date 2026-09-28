# -----------------------------------------------------------------------------
# State backend — GCS, prefix-per-customer
# -----------------------------------------------------------------------------
# Pavo-owned bucket, supplied at init (the name is in Pavo's internal runbook):
#
#   terraform init -reconfigure \
#     -backend-config="bucket=<pavo-state-bucket>" \
#     -backend-config="prefix=customer-bootstrap/${CUSTOMER_NAME}"
#
# No Terraform workspaces — prefix per customer keeps state files cleanly
# separated and matches the existing `terraform-legacy/` pattern.
# -----------------------------------------------------------------------------

terraform {
  backend "gcs" {}
}
