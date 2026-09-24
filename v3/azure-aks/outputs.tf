output "resource_group_name" {
  value = local.resource_group_name
}

# ---------------------------------------------------------------------------
# Cluster
# ---------------------------------------------------------------------------

output "aks_cluster_name" {
  value = module.aks.cluster_name
}

output "aks_kubernetes_version" {
  value       = module.aks.current_kubernetes_version
  description = "Full patch version the control plane runs, as resolved by AKS. The application requires 1.36 or newer; main.tf warns if it is older."
}

locals {
  aks_get_credentials_command = "az aks get-credentials --resource-group ${local.resource_group_name} --name ${module.aks.cluster_name} --overwrite-existing"
}

output "aks_get_credentials_command" {
  value       = local.aks_get_credentials_command
  description = "Adds the cluster to ~/.kube/config. Use with: eval \"$(terraform output -raw aks_get_credentials_command)\""
}

output "aks_oidc_issuer_url" {
  value       = module.aks.oidc_issuer_url
  description = "OIDC issuer of the cluster, for any additional federated identity credentials."
}

output "aks_node_resource_group" {
  value       = module.aks.node_resource_group
  description = "Resource group AKS creates the node VM, its disks (including the data-root volumes) and the Gateway's load balancer in."
}

output "gateway_ip_command" {
  value       = "kubectl -n ${local.gateway_namespace} get gateway ${local.gateway_name} -o jsonpath='{.status.addresses[0].value}'"
  description = "Prints the public IP of the cluster's Gateway once it is programmed: what front_door_origin reads back off the node resource group."
}

output "sandbox_runtime_check_commands" {
  description = "Both must return an object before installing any deployment. The sandbox runtime is a cluster prerequisite: see https://sema4.ai/docs/v3/deploy/sandbox-runtime."
  value = [
    "kubectl get runtimeclass kata-clh",
    "kubectl get nodes -l katacontainers.io/kata-runtime=true",
  ]
}

# ---------------------------------------------------------------------------
# Front Door
# ---------------------------------------------------------------------------

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

# ---------------------------------------------------------------------------
# PostgreSQL
#
# The server has no public endpoint, so both commands run psql in a throwaway
# in-cluster Pod. Run aks_get_credentials_command first. They carry the admin
# password, so they are sensitive: read them with `terraform output -raw`.
# ---------------------------------------------------------------------------

output "postgres_host" {
  value = module.postgres.host
}

output "postgres_admin_user" {
  value = module.postgres.admin_username
}

output "postgres_admin_password" {
  value     = module.postgres.admin_password
  sensitive = true
}

output "postgres_check_command" {
  value = join(" ", [
    "kubectl run psql-check --rm -it --restart=Never --image=postgres:17-alpine",
    "--env=PGPASSWORD=${module.postgres.admin_password}",
    "--",
    "psql -h ${module.postgres.host}",
    "-U ${module.postgres.admin_username}",
    "-d postgres",
    "-c 'select version()'",
  ])
  sensitive   = true
  description = "Connects to PostgreSQL from a throwaway Pod: proves pods can resolve, reach, and authenticate against the server. Use with: eval \"$(terraform output -raw postgres_check_command)\""
}

output "psql_command" {
  value = join(" ", [
    "kubectl run psql-admin-$(date +%s) --rm -it --restart=Never --image=postgres:17-alpine",
    "--env=PGPASSWORD=${module.postgres.admin_password}",
    "--",
    "psql -h ${module.postgres.host}",
    "-U ${module.postgres.admin_username}",
    "-d postgres",
  ])
  sensitive   = true
  description = "Interactive psql as the server admin, in a throwaway Pod: where each deployment's database SQL (in its rendered values file) is run. Use with: eval \"$(terraform output -raw psql_command)\""
}

# ---------------------------------------------------------------------------
# Deployments
# ---------------------------------------------------------------------------

output "deployments" {
  description = "Per deployment: namespace, service account, URL, database and roles, blob key prefix, Entra ID client ID, and rendered values file (which carries the one-time database SQL in its header)."
  value = {
    for name, d in local.deployments : name => {
      namespace       = name
      service_account = d.service_account
      url             = d.url
      database        = d.database
      database_roles  = local.database_roles[name]
      blob_key_prefix = name
      oidc_client_id  = try(module.entra_app[name].client_id, null)
      values_file     = local_sensitive_file.values[name].filename
    }
  }
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
  description = "The blob store shared by every deployment (each under its own key prefix), and the managed identity that reaches it."
  value = {
    storage_account_name = module.blob_store.storage_account_name
    container_name       = module.blob_store.container_name
    identity_client_id   = azurerm_user_assigned_identity.workload.client_id
  }
}

output "key_vault" {
  description = "The vault and the per-deployment keys behind infrastructure.azure.keyVaultKeyUrl. Versionless identifiers, so the deployments follow a key rotation."
  value = {
    vault_name = module.key_vault.vault_name
    key_urls   = module.key_vault.key_urls
  }
}
