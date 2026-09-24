output "storage_account_name" {
  description = "Storage account holding the container; the chart's infrastructure.azure.storageAccountName."
  value       = azurerm_storage_account.this.name
}

output "container_name" {
  description = "Blob container; the chart's infrastructure.azure.blobContainerName."
  value       = azurerm_storage_container.this.name
}

output "container_id" {
  description = "Resource Manager ID of the container, for a role assignment scoped to it rather than to the whole account."
  value       = azurerm_storage_container.this.id
}
