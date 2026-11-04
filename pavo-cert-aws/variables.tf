variable "aws_region" {
  description = "Cell region (certificate must live in the NLB's region)."
  type        = string
}

variable "instance_id" {
  description = "Omnistrate instance ID; tag only."
  type        = string
}

variable "eks_cluster_name" {
  description = "Cell cluster (hc-*); names the /pavo/cells/<cluster> gate path."
  type        = string
}

variable "customer_name" {
  description = "Customer identifier; derives <customer_name>.<base_domain> hostnames."
  type        = string
}

variable "base_domain" {
  description = "Fallback base domain when app_domain is empty."
  type        = string
  default     = "pavoai.dev"
}

variable "app_domain" {
  description = "Frontend host; API at api.<app_domain>. Empty derives <customer_name>.<base_domain>."
  type        = string
  default     = ""
  validation {
    condition     = var.app_domain == "" || can(regex("^[a-z0-9.-]+\\.[a-z]{2,}$", var.app_domain))
    error_message = "app_domain must be a bare DNS name (no scheme, no trailing dot)."
  }
}

variable "auth_hostname" {
  description = "Self-hosted Zitadel host. Empty derives auth.<customer_name>.<base_domain>."
  type        = string
  default     = ""
}

variable "network_posture" {
  description = "standard | strict. Only strict requests the edge certificate."
  type        = string
  default     = "standard"
  validation {
    condition     = contains(["standard", "strict"], var.network_posture)
    error_message = "network_posture must be either \"standard\" or \"strict\"."
  }
}
