# The shared infrastructure: one resource group, one virtual network, one
# PostgreSQL Flexible Server and one AKS cluster with a single sandbox-capable
# node. Every deployment in var.deployment_ids is hosted on these; see
# deployments.tf for what each one adds, and front-door.tf for the public edge.

resource "azurerm_resource_group" "this" {
  name     = "rg-${var.infra_id}"
  location = var.location
}

locals {
  # Where AKS creates the node VM, its disks and the Gateway's load balancer.
  # Named here rather than left to AKS, so front-door.tf can find the Gateway's
  # IP in it on a plan that runs before the cluster exists.
  node_resource_group = "rg-${var.infra_id}-aks-nodes"
}

module "networking" {
  source = "./modules/networking"

  infra_id                = var.infra_id
  resource_group_name     = azurerm_resource_group.this.name
  resource_group_location = azurerm_resource_group.this.location

  vnet_address_space = var.vnet_address_space
  aks_subnet_prefix  = var.aks_subnet_prefix
  db_subnet_prefix   = var.db_subnet_prefix
}

# PostgreSQL lives in the same virtual network as the cluster, with no public
# endpoint — see the module for how in-cluster clients reach and resolve it.
module "postgres" {
  source = "./modules/postgres"

  infra_id                = var.infra_id
  resource_group_name     = azurerm_resource_group.this.name
  resource_group_location = azurerm_resource_group.this.location

  db_subnet_id = module.networking.db_subnet_id
  vnet_id      = module.networking.vnet_id

  sku_name   = var.postgres_sku_name
  storage_mb = var.postgres_storage_mb
}

module "aks" {
  source = "./modules/aks"

  infra_id                = var.infra_id
  resource_group_name     = azurerm_resource_group.this.name
  resource_group_location = azurerm_resource_group.this.location

  aks_subnet_id        = module.networking.aks_subnet_id
  node_resource_group  = local.node_resource_group
  kubernetes_version   = var.kubernetes_version
  node_vm_size         = var.node_vm_size
  node_os_disk_size_gb = var.node_os_disk_size_gb
}
