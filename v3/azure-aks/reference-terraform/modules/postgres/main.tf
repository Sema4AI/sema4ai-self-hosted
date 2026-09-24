locals {
  admin_username = "s4admin"
}

# PostgreSQL Flexible Server in private access (VNet-injected) mode: the
# server gets a NIC in a subnet delegated to Microsoft.DBforPostgreSQL and has
# no public endpoint at all. Anything that routes inside the virtual network
# reaches it, including AKS pods — with Azure CNI Overlay a pod's outbound
# traffic leaves the node SNAT'd to the node's address in the cluster subnet,
# which is in this same network. Firewall rules do not exist in private access
# mode, so no per-client rules are needed for the cluster.
#
# One server is shared by every deployment on the cluster; each gets its own
# database and its own three least-privilege roles, which a Job in the
# cluster creates (databases.tf).
#
# TLS is required by the server (require_secure_transport defaults to on); the
# application negotiates it by default.
#
# The application supports PostgreSQL 17 or 18.
resource "azurerm_postgresql_flexible_server" "this" {
  name                = "psql-${var.infra_id}"
  version             = "18"
  resource_group_name = var.resource_group_name
  location            = var.resource_group_location

  delegated_subnet_id = var.db_subnet_id
  private_dns_zone_id = azurerm_private_dns_zone.this.id

  public_network_access_enabled = false
  administrator_login           = local.admin_username
  administrator_password        = random_password.admin.result

  storage_mb = var.storage_mb
  sku_name   = var.sku_name

  # Azure picks a zone when none is given; do not fight it on later applies.
  lifecycle {
    ignore_changes = [zone]
  }

  depends_on = [azurerm_private_dns_zone_virtual_network_link.this]
}

# Flexible Server refuses CREATE EXTENSION for anything not on this allow-list,
# whatever privileges the caller holds. The application's schema enables
# pgcrypto and citext in its first migration; both are trusted extensions, so
# the migrator role creates them by owning the database, with no superuser
# needed, but they still have to be listed here.
resource "azurerm_postgresql_flexible_server_configuration" "extensions" {
  name      = "azure.extensions"
  server_id = azurerm_postgresql_flexible_server.this.id
  value     = "PGCRYPTO,CITEXT"
}

# Private DNS zone holding the server's A record, linked to the virtual
# network so in-cluster clients resolve the FQDN to its private IP: pod ->
# CoreDNS -> the Azure-provided resolver (168.63.129.16) -> this zone. Without
# the link the FQDN does not resolve from the cluster at all.
resource "azurerm_private_dns_zone" "this" {
  name                = "${var.infra_id}.postgres.database.azure.com"
  resource_group_name = var.resource_group_name
}

resource "azurerm_private_dns_zone_virtual_network_link" "this" {
  name                  = "${var.infra_id}-vnet-link"
  resource_group_name   = var.resource_group_name
  virtual_network_id    = var.vnet_id
  private_dns_zone_name = azurerm_private_dns_zone.this.name
}

resource "random_password" "admin" {
  length  = 32
  special = false
}
