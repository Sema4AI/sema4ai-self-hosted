output "cluster_name" {
  value = azurerm_kubernetes_cluster.this.name
}

output "oidc_issuer_url" {
  value       = azurerm_kubernetes_cluster.this.oidc_issuer_url
  description = "Issuer of the federated identity credentials that target this cluster."
}

# Credentials for the kubernetes provider in the root module. Local
# (certificate) admin credentials, so no Azure CLI or Entra login is needed
# during apply.
output "kube_config" {
  value       = azurerm_kubernetes_cluster.this.kube_config[0]
  sensitive   = true
  description = "host / client_certificate / client_key / cluster_ca_certificate for the cluster admin context."
}
