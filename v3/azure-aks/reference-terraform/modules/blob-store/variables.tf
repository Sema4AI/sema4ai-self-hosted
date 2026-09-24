variable "infra_id" {
  type        = string
  description = "Infrastructure identifier; the stem of the globally unique storage account name."
}

variable "resource_group_name" {
  type = string
}

variable "resource_group_location" {
  type = string
}

variable "aks_subnet_id" {
  type        = string
  description = "Node subnet of the cluster. The storage account firewall denies everything else; pod traffic arrives SNAT'd to a node address in this subnet."
}

variable "replication_type" {
  type        = string
  description = "Storage account replication (LRS, ZRS, GRS, GZRS, ...)."
}
