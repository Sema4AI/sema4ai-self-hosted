terraform {
  required_providers {
    azapi = {
      source = "Azure/azapi"
    }
  }
}

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
  default_node_pool {
    name                 = "default"
    vm_size              = var.node_vm_size
    node_count           = 1
    os_disk_size_gb      = var.node_os_disk_size_gb
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

  # The application routing add-on, without its NGINX ingress controller,
  # which is retired: Microsoft supports it only through November 2026.
  # Ingress is the add-on's Gateway API implementation instead
  # (azapi_update_resource.gateway_api below). No DNS zone integration: the
  # public hostnames are Front Door's (see front-door.tf).
  web_app_routing {
    dns_zone_ids             = []
    default_nginx_controller = "None"
  }

  lifecycle {
    # Azure fills default_node_pool.upgrade_settings with its own defaults on
    # creation; without this, every plan proposes clearing them again.
    ignore_changes = [default_node_pool[0].upgrade_settings]
  }
}

# The Kubernetes Gateway API: the AKS-managed CRDs (installation "Standard",
# their bundle version tied to the cluster's Kubernetes minor version) and the
# application routing add-on's implementation of them, which runs a
# sidecar-less Istio control plane in aks-istio-system and serves the
# approuting-istio GatewayClass that the Gateway in gateway.tf names.
#
# azapi, because azurerm_kubernetes_cluster has no argument for either. This
# is the shape of Microsoft's own Terraform sample for the feature. The
# resource reads the cluster, merges this body into it and writes it back, so
# it runs after the cluster (referencing its ID guarantees that) and, on
# every later plan, compares only these fields.
#
# The two resources share ingressProfile. When web_app_routing above changes,
# azurerm rebuilds that profile without these fields; this resource restores
# them on the same apply, but disabling the managed CRDs even briefly deletes
# every Gateway and HTTPRoute with them. Change web_app_routing with that in
# mind.
resource "azapi_update_resource" "gateway_api" {
  type        = "Microsoft.ContainerService/managedClusters@2026-05-01"
  resource_id = azurerm_kubernetes_cluster.this.id

  body = {
    properties = {
      ingressProfile = {
        gatewayAPI = {
          installation = "Standard"
        }
        webAppRouting = {
          gatewayAPIImplementations = {
            appRoutingIstio = {
              mode = "Enabled"
            }
          }
        }
      }
    }
  }
}
