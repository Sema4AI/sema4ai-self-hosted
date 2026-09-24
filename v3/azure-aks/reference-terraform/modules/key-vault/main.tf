# The Key Vault behind the chart's infrastructure.azure.keyVaultKeyUrl: one
# vault for the infrastructure, one RSA key per deployment, and the workload
# identity granted crypto rights on each key.
#
# The chart requires the key identifier on infrastructure.platform=azure and
# checks its shape when it renders. The key is reserved as the envelope key
# for the application's secrets at rest, and for encrypting small values
# directly under it: required now, so the install contract is final before
# those features ship. Treat each key as durable from the start: once the
# application wraps secrets with it, destroying the key makes them
# unreadable, exactly like the api.config.secretsKeys keyring in the values
# file.
#
# Isolation is per deployment, matching the rest of the stack: one shared
# vault with one key per deployment, as the blob store is one container with a
# key prefix per deployment and PostgreSQL one server with a database per
# deployment.

data "azurerm_client_config" "current" {}

resource "azurerm_key_vault" "this" {
  # 3-24 characters, alphanumerics and single hyphens, beginning with a
  # letter. Globally unique, like the storage account name.
  name                = substr("kv-${var.infra_id}-s4ai", 0, 24)
  resource_group_name = var.resource_group_name
  location            = var.resource_group_location
  tenant_id           = data.azurerm_client_config.current.tenant_id
  sku_name            = "standard"

  # Azure RBAC rather than vault access policies, so a role assignment can be
  # scoped to a single key.
  rbac_authorization_enabled = true

  # Soft delete is mandatory; the retention window is how long a deleted key
  # can still be recovered. Purge protection makes that recovery the only
  # option: it cannot be turned off once on, and it blocks `terraform
  # destroy` from actually removing the vault for the whole window.
  soft_delete_retention_days = var.soft_delete_retention_days
  purge_protection_enabled   = var.purge_protection_enabled

  # No network_acls: creating a key is a data-plane call, so a firewall here
  # would have to allow whatever address `terraform apply` runs from, not just
  # the cluster subnet. Azure RBAC is the gate.
}

# Terraform creates the keys below through the data plane, which RBAC gates
# separately from the control-plane rights that created the vault. Crypto
# Officer is the key-management role, scoped to this vault only.
#
# Azure RBAC can take a couple of minutes to reach the data plane, so a first
# apply can fail key creation with 403 Forbidden. Re-running apply is the fix;
# nothing is left half-created.
resource "azurerm_role_assignment" "terraform_crypto_officer" {
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Crypto Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}

# RSA, because the application wraps data keys with it; 3072 bits is the
# smallest size still recommended for long-lived wrapping keys.
#
# key_opts are every operation the application may run with the key:
# wrapKey and unwrapKey for envelope encryption, and encrypt and decrypt,
# reserved for encrypting small values directly. Changing key_opts updates
# the key in place; it does not replace the key.
resource "azurerm_key_vault_key" "this" {
  for_each = var.deployment_ids

  name         = "${each.key}-secrets"
  key_vault_id = azurerm_key_vault.this.id
  key_type     = "RSA"
  key_size     = 3072
  key_opts     = ["decrypt", "encrypt", "unwrapKey", "wrapKey"]

  depends_on = [azurerm_role_assignment.terraform_crypto_officer]
}

# get, encrypt, decrypt, wrapKey, and unwrapKey for the deployment, scoped to
# its own key rather than to the vault. The versionless resource ID keeps the
# assignment attached across a key rotation.
resource "azurerm_role_assignment" "workload_crypto_user" {
  for_each = var.deployment_ids

  scope                = azurerm_key_vault_key.this[each.key].resource_versionless_id
  role_definition_name = "Key Vault Crypto User"
  principal_id         = var.workload_principal_id
}
