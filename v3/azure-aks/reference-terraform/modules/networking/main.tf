resource "azurerm_virtual_network" "this" {
  name                = "vnet-${var.infra_id}"
  resource_group_name = var.resource_group_name
  location            = var.resource_group_location
  address_space       = [var.vnet_address_space]
}

# Subnet the PostgreSQL Flexible Server is injected into. Delegated to the
# service, and must hold nothing else. Reachable from the node subnet below
# because both sit in this virtual network.
resource "azurerm_subnet" "db" {
  name                 = "snet-${var.infra_id}-db"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [var.db_subnet_prefix]

  delegation {
    name = "fs"
    service_delegation {
      name = "Microsoft.DBforPostgreSQL/flexibleServers"
      actions = [
        "Microsoft.Network/virtualNetworks/subnets/join/action",
      ]
    }
  }
}

# Subnet for the AKS node pool. Pod IPs are not allocated from here — the
# cluster uses Azure CNI Overlay, so only node IPs come from this subnet, and
# pod traffic leaving a node is SNAT'd to that node's address. That is why
# this subnet is what the storage account firewall allows, and why the
# in-network PostgreSQL server accepts connections from pods.
resource "azurerm_subnet" "aks" {
  name                 = "snet-${var.infra_id}-aks"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [var.aks_subnet_prefix]
  service_endpoints    = ["Microsoft.Storage"]
}
