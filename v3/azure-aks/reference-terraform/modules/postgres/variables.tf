variable "infra_id" {
  type = string
}

variable "resource_group_name" {
  type = string
}

variable "resource_group_location" {
  type = string
}

variable "db_subnet_id" {
  type        = string
  description = "Subnet delegated to Microsoft.DBforPostgreSQL/flexibleServers that the server is injected into. Must hold no other resources."
}

variable "vnet_id" {
  type        = string
  description = "Virtual network the private DNS zone is linked to, so clients in it (AKS pods) resolve the server's FQDN."
}

variable "sku_name" {
  type        = string
  description = "Compute SKU of the Flexible Server."
}

variable "storage_mb" {
  type        = number
  description = "Storage size in MB. Can only ever grow."
}

variable "storage_tier" {
  type        = string
  description = "Storage performance tier (P4/P6/P10/...), constrained by storage_mb."
}

variable "max_connections" {
  type        = number
  description = "max_connections server parameter. Changing it restarts the server."
}
