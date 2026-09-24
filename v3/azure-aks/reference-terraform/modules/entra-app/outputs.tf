output "client_id" {
  value = azuread_application.this.client_id
}

output "client_secret" {
  value     = azuread_application_password.this.value
  sensitive = true
}

output "issuer" {
  value = "https://login.microsoftonline.com/${data.azuread_client_config.current.tenant_id}/v2.0"
}
