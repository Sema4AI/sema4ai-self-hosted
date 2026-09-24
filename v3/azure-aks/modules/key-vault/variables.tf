variable "infra_id" {
  type        = string
  description = "Infrastructure identifier; the stem of the globally unique vault name."
}

variable "resource_group_name" {
  type = string
}

variable "resource_group_location" {
  type = string
}

variable "deployment_ids" {
  type        = set(string)
  description = "Deployment names. One key per name, granted to the workload identity below."
}

variable "workload_principal_id" {
  type        = string
  description = "Principal ID of the user-assigned managed identity the application federates into; granted Key Vault Crypto User on each key."
}

variable "purge_protection_enabled" {
  type        = bool
  description = "Enable Key Vault purge protection. Irreversible, and it blocks `terraform destroy` from removing the vault for the soft-delete window."
  default     = false
}

variable "soft_delete_retention_days" {
  type        = number
  description = "Days a deleted key or vault stays recoverable (7-90)."
  default     = 7
}
