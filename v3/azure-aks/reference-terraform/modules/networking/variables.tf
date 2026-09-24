variable "infra_id" {
  type = string
}

variable "resource_group_name" {
  type = string
}

variable "resource_group_location" {
  type = string
}

variable "vnet_address_space" {
  type        = string
  description = "Address space of the virtual network."
}

variable "aks_subnet_prefix" {
  type        = string
  description = "Node subnet of the cluster."
}

variable "db_subnet_prefix" {
  type        = string
  description = "Subnet delegated to PostgreSQL Flexible Server."
}
