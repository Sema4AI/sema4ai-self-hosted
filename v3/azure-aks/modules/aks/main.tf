resource "azurerm_kubernetes_cluster" "this" {
  name                = "aks-${var.infra_id}"
  resource_group_name = var.resource_group_name
  location            = var.resource_group_location
  dns_prefix          = "${var.infra_id}-aks"
  node_resource_group = var.node_resource_group
  sku_tier            = "Free"

  kubernetes_version = var.kubernetes_version

  # The OIDC issuer and workload identity power the federation that lets the
  # application's pods exchange their projected service account token for an
  # Entra token of a user-assigned managed identity. Both must be on for a
  # federated identity credential on this cluster to work.
  oidc_issuer_enabled       = true
  workload_identity_enabled = true

  # One node pool, one node, no autoscaler — the shape the application
  # requires. It carries the whole application plus every concurrent sandbox
  # run, so the VM size is the ceiling on concurrent agent work; adding nodes
  # does not raise it, and an autoscaler replacing the node takes the
  # deployments down and discards their data-root caches. AKS system pods
  # share the node.
  #
  # The pool is pinned to one availability zone, where the data-root disks
  # are created.
  default_node_pool {
    name                 = "default"
    vm_size              = var.node_vm_size
    node_count           = 1
    os_disk_size_gb      = var.node_os_disk_size_gb
    zones                = var.node_zones
    vnet_subnet_id       = var.aks_subnet_id
    auto_scaling_enabled = false

    # Lets the provider rotate the pool in place (vm_size, os_disk_size_gb)
    # through a temporary pool instead of replacing the whole cluster. The
    # node is replaced either way, so the deployments go down and their data
    # roots start cold.
    temporary_name_for_rotation = "defaulttmp"
  }

  identity {
    type = "SystemAssigned"
  }

  # Azure CNI Overlay: nodes take subnet IPs, pods live on an overlay CIDR.
  # Pod traffic leaving the node is SNAT'd to the node's address, which is
  # what the storage account firewall and the PostgreSQL server see.
  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = "overlay"
    pod_cidr            = "10.244.0.0/16"
    service_cidr        = "10.96.0.0/16"
    dns_service_ip      = "10.96.0.10"
  }

  # The application routing add-on: an Azure-managed NGINX ingress controller
  # behind one public Standard load balancer, with the ingress class
  # webapprouting.kubernetes.azure.com that the chart derives on
  # infrastructure.platform=azure. No DNS zone integration: the public
  # hostnames are Front Door's (see front-door.tf).
  web_app_routing {
    dns_zone_ids = []
  }

  lifecycle {
    # Azure fills default_node_pool.upgrade_settings with its own defaults on
    # creation; without this, every plan proposes clearing them again.
    ignore_changes = [default_node_pool[0].upgrade_settings]
  }
}
