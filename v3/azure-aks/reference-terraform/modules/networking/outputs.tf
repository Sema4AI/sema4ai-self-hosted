output "vnet_id" {
  value = azurerm_virtual_network.this.id
}

output "db_subnet_id" {
  value = azurerm_subnet.db.id
}

output "aks_subnet_id" {
  value = azurerm_subnet.aks.id
}
