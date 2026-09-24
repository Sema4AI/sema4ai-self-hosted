# The blob store shared by every deployment on this cluster: one storage
# account, one container, and a key prefix per deployment inside it (the
# chart's infrastructure.azure.blobKeyPrefix, which deployments.tf sets to the
# deployment name).
#
# The application reaches it with Azure Workload Identity, never an account
# key: the identity in deployments.tf holds Storage Blob Data Contributor on
# the container, and the chart labels its VFS Pods so the AKS webhook projects
# the federated token the application exchanges for that identity.
#
# This is the system of record for workspace files. The data root on the node
# is a cache in front of it: a replaced node re-materializes from here.
#
# Moving between locally redundant (LRS, GRS, RAGRS) and zone-redundant (ZRS,
# GZRS, RAGZRS) replication makes Terraform replace the account, and every
# blob in it.

resource "azurerm_storage_account" "this" {
  # 3-24 lowercase alphanumerics, globally unique.
  name                     = substr("st${var.infra_id}s4ai", 0, 24)
  resource_group_name      = var.resource_group_name
  location                 = var.resource_group_location
  account_tier             = "Standard"
  account_replication_type = var.replication_type

  allow_nested_items_to_be_public   = false
  infrastructure_encryption_enabled = true
  min_tls_version                   = "TLS1_2"
}

resource "azurerm_storage_container" "this" {
  name                  = "sema4ai-blobs"
  storage_account_id    = azurerm_storage_account.this.id
  container_access_type = "private"
}

# Everything denied except the AKS node subnet, which the cluster reaches
# through the Microsoft.Storage service endpoint on that subnet. Pod traffic
# arrives SNAT'd to a node address (Azure CNI Overlay), so allowing the node
# subnet allows the application's Pods.
#
# The rule also denies your workstation, including the Azure portal's blob
# browser: allow your address in temporarily to inspect the container (see
# README.md).
resource "azurerm_storage_account_network_rules" "this" {
  storage_account_id = azurerm_storage_account.this.id

  default_action             = "Deny"
  bypass                     = ["AzureServices"]
  virtual_network_subnet_ids = [var.aks_subnet_id]
}
