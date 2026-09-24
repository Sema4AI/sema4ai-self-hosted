output "host" {
  value       = azurerm_postgresql_flexible_server.this.fqdn
  description = "Private FQDN of the server. Only resolvable and reachable from inside the virtual network, which includes AKS pods."
}

output "admin_username" {
  value = local.admin_username
}

output "admin_password" {
  value     = random_password.admin.result
  sensitive = true
}
