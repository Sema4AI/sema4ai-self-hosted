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
  description = "Deployment names. One key per name."
}

variable "workload_principal_id" {
  type        = string
  description = "Principal ID of the user-assigned managed identity the application federates into; granted Key Vault Crypto User on the vault."
}
