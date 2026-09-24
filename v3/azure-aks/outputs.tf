# Only what README.md uses. Everything else is in state, for
# `terraform state show` or an output of your own.

output "resource_group_name" {
  value = local.resource_group_name
}

output "aks_get_credentials_command" {
  value       = "az aks get-credentials --resource-group ${local.resource_group_name} --name ${module.aks.cluster_name} --overwrite-existing"
  description = "Adds the cluster to ~/.kube/config. Use with: eval \"$(terraform output -raw aks_get_credentials_command)\""
}

output "front_door_endpoints" {
  description = "The public URL of every deployment: an Azure-generated Front Door endpoint with a Microsoft-managed certificate. These are the applicationUrl and httpRoute hostname in the rendered values files, and the redirect URIs of the Entra ID app registrations."
  value       = { for name, d in local.deployments : name => d.url }
}

output "front_door_origin" {
  description = "The origin every endpoint forwards to: the public IP of the cluster's Gateway, reached over HTTP and admitted only from the AzureFrontDoor.Backend service tag. Null means the Gateway had no IP yet when this apply was planned, so the origin and routes were skipped: wait for the Gateway to be programmed, then apply again."
  value       = local.ingress_public_ip
}

output "front_door_id" {
  description = "This Front Door profile's ID, sent as the X-Azure-FDID header on every request to the origin. Checking it at the Gateway is what would narrow the origin from every Front Door to this one (see README.md)."
  value       = azurerm_cdn_frontdoor_profile.this.resource_guid
}

output "helm_install_commands" {
  description = "Per deployment, the `helm upgrade --install` that installs it on the first run and upgrades it after, with the release name and namespace both set to the deployment name and the kube context pinned to this cluster. Replace <chart> with the chart reference for your version. Print one with: terraform output -json helm_install_commands | jq -r --arg d <deployment> '.[$d]'"
  value = {
    for name in keys(local.deployments) : name => join(" ", [
      "helm upgrade --install ${name} <chart>",
      "--kube-context ${module.aks.cluster_name}",
      "--namespace ${name}",
      "-f ${local_sensitive_file.values[name].filename}",
    ])
  }
}

output "blob_store" {
  description = "The blob store shared by every deployment (each under its own key prefix)."
  value = {
    storage_account_name = module.blob_store.storage_account_name
    container_name       = module.blob_store.container_name
  }
}
