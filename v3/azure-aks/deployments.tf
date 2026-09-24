# The application deployments hosted on the shared infrastructure: the blob
# store and the managed identity that reaches it, the Key Vault, and — per
# var.deployment_ids entry — a namespace + service account, a federated
# identity credential, an Entra ID app registration, generated credentials and
# keys, and a fully rendered values file.
#
# Terraform renders the values, creates the namespace, and creates the
# database and roles (databases.tf); installing is a plain
# `helm install <name> <chart> -n <name> -f rendered/values-<name>.yaml`.

locals {
  chart_name = "blockparty"

  # Deployment name => derived facts. The Helm release name is the deployment
  # name, so every resource the chart derives is per deployment, including the
  # data root, mounted under /var/lib/blockparty/<release>.
  deployments = {
    for name in var.deployment_ids : name => {
      service_account = "${name}-app"
      # The chart's fullname: <release>-blockparty, collapsed to the release
      # name when that already contains "blockparty".
      chart_fullname = strcontains(name, local.chart_name) ? name : "${name}-${local.chart_name}"
      # Prefixed, so no deployment name can collide with an existing database
      # (postgres) or a reserved word (user, order) in the SQL.
      database       = "s4_${replace(name, "-", "_")}"
      data_root_path = "/var/lib/blockparty/${name}"
      # The public hostname is the deployment's Front Door endpoint, generated
      # by Azure and only known after an apply. It is both the hostname of the
      # HTTPRoute the chart renders, which the Gateway matches on, and, as the
      # values file's applicationUrl, the origin the chart derives every URL
      # the application hands a browser from.
      host = azurerm_cdn_frontdoor_endpoint.deployment[name].host_name
      url  = "https://${azurerm_cdn_frontdoor_endpoint.deployment[name].host_name}"
    }
  }

  # PostgreSQL roles are server-wide on the shared Flexible Server, so each
  # deployment gets its own set, named after its database.
  database_roles = {
    for name, d in local.deployments : name => {
      app      = "${d.database}_app"
      definer  = "${d.database}_definer"
      migrator = "${d.database}_migrator"
    }
  }
}

# ---------------------------------------------------------------------------
# The blob store and the identity that reaches it.
#
# One storage account and container for every deployment (separated by key
# prefix, as the databases are by name), and one user-assigned managed
# identity that holds Storage Blob Data Contributor on that container and Key
# Vault Crypto User on each deployment's key. Those are the only Azure
# permissions the application needs.
#
# The chart labels its VFS Pods `azure.workload.identity/use: "true"` on
# infrastructure.platform=azure, so the AKS webhook projects a federated token
# for the client ID annotated on the deployment's service account below, and
# the application exchanges it for this identity. Nothing else in the release
# gets an Azure credential.
# ---------------------------------------------------------------------------

module "blob_store" {
  source = "./modules/blob-store"

  infra_id                = var.infra_id
  resource_group_name     = local.resource_group_name
  resource_group_location = local.resource_group_location
  aks_subnet_id           = module.networking.aks_subnet_id
  replication_type        = var.blob_replication_type
}

resource "azurerm_user_assigned_identity" "workload" {
  name                = "id-${var.infra_id}-sema4ai"
  resource_group_name = local.resource_group_name
  location            = local.resource_group_location
}

# Scoped to the container, not the account: an account-level grant would reach
# anything else ever added to it.
resource "azurerm_role_assignment" "blob_contributor" {
  scope                = module.blob_store.container_id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_user_assigned_identity.workload.principal_id
}

module "key_vault" {
  source = "./modules/key-vault"

  infra_id                = var.infra_id
  resource_group_name     = local.resource_group_name
  resource_group_location = local.resource_group_location

  deployment_ids        = var.deployment_ids
  workload_principal_id = azurerm_user_assigned_identity.workload.principal_id

  purge_protection_enabled = var.key_vault_purge_protection
}

# One credential per deployment: federation is per service account subject,
# so a shared identity still needs an entry per namespace (Azure allows 20 per
# identity, which caps the deployments per identity). The subject must match
# the namespace and service account exactly; a mismatch fails at token
# exchange, and blob operations then fail with 403.
resource "azurerm_federated_identity_credential" "deployment" {
  for_each = local.deployments

  name                      = "aks-${each.key}"
  user_assigned_identity_id = azurerm_user_assigned_identity.workload.id
  audience                  = ["api://AzureADTokenExchange"]
  issuer                    = module.aks.oidc_issuer_url
  subject                   = "system:serviceaccount:${each.key}:${each.value.service_account}"
}

module "app_namespace" {
  source   = "./modules/app-namespace"
  for_each = local.deployments

  namespace       = each.key
  service_account = each.value.service_account
  # app.kubernetes.io/part-of is also what lets the chart's HTTPRoute attach:
  # the Gateway (gateway.tf) admits routes only from namespaces carrying it.
  labels = {
    "app.kubernetes.io/managed-by" = "terraform"
    "app.kubernetes.io/part-of"    = "sema4ai"
  }

  # What binds the account to the identity above.
  service_account_annotations = {
    "azure.workload.identity/client-id" = azurerm_user_assigned_identity.workload.client_id
  }

  depends_on = [module.aks]
}

# Entra ID app registration per deployment, registered against the
# deployment's hostname. The redirect URI must match what the chart derives
# from applicationUrl, /api/v1/auth/callback on that origin.
# Set create_entra_apps = false to bring your own identity provider.
module "entra_app" {
  source   = "./modules/entra-app"
  for_each = var.create_entra_apps ? local.deployments : {}

  display_name  = "Sema4.ai ${var.infra_id} ${each.key}"
  redirect_uris = ["${each.value.url}/api/v1/auth/callback"]
  logout_url    = each.value.url
}

# ---------------------------------------------------------------------------
# Per-deployment credentials and key material, generated once and kept in
# state.
#
# The two role passwords are what the database setup (databases.tf) assigns
# and the rendered values file connects with. The two keys are durable:
# destroying and recreating them makes data already encrypted with them
# unreadable, so treat removing a deployment from var.deployment_ids as a
# data-destroying change. The application's internal service tokens are
# deliberately absent: the chart generates them and reuses them across
# upgrades.
# ---------------------------------------------------------------------------

resource "random_password" "app_role" {
  for_each = local.deployments

  length  = 32
  special = false
}

resource "random_password" "migrator_role" {
  for_each = local.deployments

  length  = 32
  special = false
}

# Encrypts the credentials the platform stores in its database: model
# platform keys, integration and OAuth tokens. The database outlives the
# cluster and cannot be read back without this exact value.
resource "random_password" "secrets_key" {
  for_each = local.deployments

  length  = 48
  special = false
}

# Encrypts exported project archives.
resource "random_password" "portability_key" {
  for_each = local.deployments

  length  = 48
  special = false
}

# Per-deployment Helm values: the minimum the chart needs on this cluster.
# Every key is a credential, a name-derived or shared-infrastructure fact, one
# of the Azure resource identifiers the chart derives its azure platform
# conventions from, or the Gateway its HTTPRoute attaches to.
#
# Contains database passwords, encryption keys and the OIDC client secret, so
# the file is owner-only (0600) and rendered/ is gitignored.
resource "local_sensitive_file" "values" {
  for_each = local.deployments

  filename = "${path.module}/rendered/values-${each.key}.yaml"
  content = templatefile("${path.module}/templates/values.yaml.tftpl", {
    deployment_id   = each.key
    service_account = each.value.service_account
    chart_fullname  = each.value.chart_fullname
    data_root_path  = each.value.data_root_path

    postgres_host              = module.postgres.host
    postgres_database          = each.value.database
    postgres_app_role          = local.database_roles[each.key].app
    postgres_app_password      = random_password.app_role[each.key].result
    postgres_definer_role      = local.database_roles[each.key].definer
    postgres_migrator_role     = local.database_roles[each.key].migrator
    postgres_migrator_password = random_password.migrator_role[each.key].result

    storage_account_name = module.blob_store.storage_account_name
    blob_container_name  = module.blob_store.container_name
    blob_key_prefix      = each.key
    workload_client_id   = azurerm_user_assigned_identity.workload.client_id
    key_vault_key_url    = module.key_vault.key_urls[each.key]

    application_url   = each.value.url
    host              = each.value.host
    gateway_name      = local.gateway_name
    gateway_namespace = local.gateway_namespace
    gateway_listener  = local.gateway_listener

    oidc_server        = try(module.entra_app[each.key].issuer, "REPLACE_ME")
    oidc_client_id     = try(module.entra_app[each.key].client_id, "REPLACE_ME")
    oidc_client_secret = try(module.entra_app[each.key].client_secret, "REPLACE_ME")

    secrets_key     = random_password.secrets_key[each.key].result
    portability_key = random_password.portability_key[each.key].result
  })
  file_permission      = "0600"
  directory_permission = "0700"
}
