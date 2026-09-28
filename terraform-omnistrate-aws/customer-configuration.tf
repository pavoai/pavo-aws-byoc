# -----------------------------------------------------------------------------
# Per-customer configuration — PUBLIC STAND-IN
# -----------------------------------------------------------------------------
# This file differs from the one Pavo deploys. The real file holds optional
# per-customer FinOps cost-allocation tags, keyed by customer name, so it is
# not published. Its shape is identical: variables.tf looks up
# local.customer_configuration.customers[var.customer_name].tags and merges any
# tags found under the Pavo standard tags (managed_by / customer / environment /
# instance), which always win on key collision. A customer without an entry
# gets no extra tags. Nothing else reads this local.
locals {
  customer_configuration = {
    customers = {}
  }
}
