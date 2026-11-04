# pavoInfra validates this ARN and re-exports it as edge_certificate_arn;
# ingress-nginx reads that one, never this (a PENDING cert must not reach the NLB).
output "certificate_arn" {
  description = "ACM certificate ARN; empty on standard posture."
  value       = local.strict ? aws_acm_certificate.edge[0].arn : ""
}

# Pavo reads these from `omctl instance describe` (result_params). One record
# per distinct base name: Pavo creates the pavoai.dev one; the record for a
# custom app_domain goes to the customer to create in their DNS.
output "validation_dns_records" {
  description = "Newline-joined '<name> <type> <value>' lines; empty on standard posture."
  value       = join("\n", [for r in local.validation_records : "${r.name} ${r.type} ${r.value}"])
}
