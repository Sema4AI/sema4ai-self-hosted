# Versionless on purpose: the chart treats an identifier without a trailing
# /<version> as "follow this key's rotation".
output "key_urls" {
  description = "Deployment name => versionless Key Vault key identifier; the chart's infrastructure.azure.keyVaultKeyUrl."
  value       = { for name, key in azurerm_key_vault_key.this : name => key.versionless_id }
}
