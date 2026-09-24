output "cluster_name" {
  value = azurerm_kubernetes_cluster.this.name
}

output "kubernetes_version" {
  value       = azurerm_kubernetes_cluster.this.kubernetes_version
  description = "Kubernetes version the cluster is configured with (minor only when that is what was asked for). What the version check in main.tf reads."
}

output "current_kubernetes_version" {
  value       = azurerm_kubernetes_cluster.this.current_kubernetes_version
  description = "Full patch version the control plane currently runs, as resolved by AKS."
}

output "oidc_issuer_url" {
  value       = azurerm_kubernetes_cluster.this.oidc_issuer_url
  description = "Issuer of the federated identity credentials that target this cluster."
}

output "node_resource_group" {
  value       = azurerm_kubernetes_cluster.this.node_resource_group
  description = "Resource group AKS creates the node VM, its disks (including the data-root volumes) and the ingress load balancer in."
}

# Credentials for the kubernetes provider in the root module. Local
# (certificate) admin credentials, so no Azure CLI or Entra login is needed
# during apply.
output "kube_config" {
  value       = azurerm_kubernetes_cluster.this.kube_config[0]
  sensitive   = true
  description = "host / client_certificate / client_key / cluster_ca_certificate for the cluster admin context."
}
