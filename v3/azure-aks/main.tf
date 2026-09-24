# The shared infrastructure: one resource group, one virtual network, one
# PostgreSQL Flexible Server and one AKS cluster with a single sandbox-capable
# node. Every deployment in var.deployment_ids is hosted on these; see
# deployments.tf for what each one adds, and front-door.tf for the public edge.

resource "azurerm_resource_group" "this" {
  name     = "rg-${var.infra_id}"
  location = var.location
}

locals {
  resource_group_name     = azurerm_resource_group.this.name
  resource_group_location = azurerm_resource_group.this.location

  # Where AKS creates the node VM, its disks and the Gateway's load balancer.
  # Named here rather than left to AKS, so front-door.tf can find the Gateway's
  # IP in it on a plan that runs before the cluster exists.
  node_resource_group = "rg-${var.infra_id}-aks-nodes"
}

module "networking" {
  source = "./modules/networking"

  infra_id                = var.infra_id
  resource_group_name     = local.resource_group_name
  resource_group_location = local.resource_group_location

  vnet_address_space = var.vnet_address_space
  aks_subnet_prefix  = var.aks_subnet_prefix
  db_subnet_prefix   = var.db_subnet_prefix
}

# PostgreSQL lives in the same virtual network as the cluster, with no public
# endpoint — see the module for how in-cluster clients reach and resolve it.
module "postgres" {
  source = "./modules/postgres"

  infra_id                = var.infra_id
  resource_group_name     = local.resource_group_name
  resource_group_location = local.resource_group_location

  db_subnet_id = module.networking.db_subnet_id
  vnet_id      = module.networking.vnet_id

  sku_name        = var.postgres_sku_name
  storage_mb      = var.postgres_storage_mb
  storage_tier    = var.postgres_storage_tier
  max_connections = var.postgres_max_connections
}

module "aks" {
  source = "./modules/aks"

  infra_id                = var.infra_id
  resource_group_name     = local.resource_group_name
  resource_group_location = local.resource_group_location

  aks_subnet_id        = module.networking.aks_subnet_id
  node_resource_group  = local.node_resource_group
  kubernetes_version   = var.kubernetes_version
  node_vm_size         = var.node_vm_size
  node_os_disk_size_gb = var.node_os_disk_size_gb
  node_zones           = var.node_zones
}

# The application needs Kubernetes 1.36 or newer. The check reads the version
# the cluster ended up configured with rather than the input, and warns
# instead of failing: the cluster itself still stands up, and only the
# application is unsupported on it.
check "kubernetes_version_supported" {
  assert {
    condition = anytrue([
      tonumber(split(".", module.aks.kubernetes_version)[0]) > 1,
      tonumber(split(".", module.aks.kubernetes_version)[1]) >= 36,
    ])
    error_message = "The cluster runs Kubernetes ${module.aks.kubernetes_version}; the application requires 1.36 or newer. Set kubernetes_version to a 1.36+ version offered in this region (az aks get-versions --location '${var.location}' --output table)."
  }
}
