variable "infra_id" {
  type = string
}

variable "resource_group_name" {
  type = string
}

variable "resource_group_location" {
  type = string
}

variable "aks_subnet_id" {
  type        = string
  description = "Subnet for the node pool. Pod IPs come from the CNI Overlay pod CIDR, not this subnet."
}

variable "node_resource_group" {
  type        = string
  description = "Name of the resource group AKS creates for the node VM, its disks and the load balancers. Must not exist beforehand."
}

variable "kubernetes_version" {
  type        = string
  description = "Kubernetes version, minor only; AKS picks the patch."
}

variable "node_vm_size" {
  type        = string
  description = "VM size of the node pool. Must support nested virtualization."
}

variable "node_os_disk_size_gb" {
  type        = number
  description = "OS disk size of the node, in GiB."
}

variable "node_zones" {
  type        = list(string)
  description = "Availability zone the node pool runs in."
}
