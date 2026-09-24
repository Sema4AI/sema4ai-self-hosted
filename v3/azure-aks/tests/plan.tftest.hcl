# Offline plan checks with mock providers: no Azure credentials needed.
#
#   terraform init -backend=false && terraform test
#
# They guard the part of this configuration that decides what exists on each
# apply: the Front Door origin, routes and network security group appear only
# once the ingress IP does, and the rest is planned per deployment.

mock_provider "azurerm" {
  mock_data "azurerm_client_config" {
    defaults = {
      tenant_id       = "11111111-1111-1111-1111-111111111111"
      object_id       = "22222222-2222-2222-2222-222222222222"
      subscription_id = "00000000-0000-0000-0000-000000000000"
    }
  }
  mock_data "azurerm_resources" {
    defaults = { resources = [] }
  }
}
mock_provider "azuread" {}
mock_provider "kubernetes" {}
mock_provider "local" {}

variables {
  subscription_id = "00000000-0000-0000-0000-000000000000"
  infra_id        = "s4aitest"
  location        = "East US 2"
  deployment_ids  = ["sema4ai", "staging"]
}

run "first_apply_no_ingress_ip" {
  command = plan
  assert {
    condition     = length(azurerm_cdn_frontdoor_origin.ingress) == 0 && length(azurerm_cdn_frontdoor_route.deployment) == 0 && length(azurerm_network_security_group.ingress) == 0
    error_message = "origin, routes and NSG must be skipped without an ingress IP"
  }
  assert {
    condition     = length(azurerm_cdn_frontdoor_endpoint.deployment) == 2 && length(module.entra_app) == 2 && length(local_sensitive_file.values) == 2
    error_message = "endpoints, Entra apps and values files must be planned per deployment"
  }
}

run "second_apply_with_ingress_ip" {
  command = plan
  override_data {
    target = data.azurerm_resources.public_ips
    values = {
      resources = [
        # Another LoadBalancer Service in this cluster, and the add-on's
        # ingress IP, which the tag singles out.
        { name = "kubernetes-0000", resource_group_name = "RG-S4AITEST-AKS-NODES", id = "w", type = "Microsoft.Network/publicIPAddresses", location = "eastus2", tags = { "k8s-azure-service" = "default/other" } },
        { name = "kubernetes-a1b2", resource_group_name = "RG-S4AITEST-AKS-NODES", id = "x", type = "Microsoft.Network/publicIPAddresses", location = "eastus2", tags = { "k8s-azure-service" = "app-routing-system/nginx" } },
        # The same Service in some other cluster's node resource group.
        { name = "kubernetes-c3d4", resource_group_name = "rg-othercluster-nodes", id = "y", type = "Microsoft.Network/publicIPAddresses", location = "eastus2", tags = { "k8s-azure-service" = "app-routing-system/nginx" } },
      ]
    }
  }
  override_data {
    target = data.azurerm_public_ip.ingress[0]
    values = { ip_address = "20.1.2.3" }
  }
  assert {
    condition     = data.azurerm_public_ip.ingress[0].name == "kubernetes-a1b2"
    error_message = "must pick the add-on's tagged IP in this cluster's node resource group"
  }
  assert {
    condition     = length(azurerm_cdn_frontdoor_origin.ingress) == 1 && azurerm_cdn_frontdoor_origin.ingress[0].host_name == "20.1.2.3"
    error_message = "origin must point at the discovered ingress IP"
  }
  assert {
    condition     = length(azurerm_cdn_frontdoor_route.deployment) == 2 && length(azurerm_network_security_group.ingress) == 1
    error_message = "routes and NSG must be created once the ingress IP exists"
  }
}

run "ingress_ip_by_name_prefix_fallback" {
  command = plan
  override_data {
    target = data.azurerm_resources.public_ips
    values = {
      resources = [
        { name = "4f2e0c1a-outbound", resource_group_name = "rg-s4aitest-aks-nodes", id = "o", type = "Microsoft.Network/publicIPAddresses", location = "eastus2", tags = {} },
        { name = "kubernetes-e5f6", resource_group_name = "rg-s4aitest-aks-nodes", id = "z", type = "Microsoft.Network/publicIPAddresses", location = "eastus2", tags = {} },
      ]
    }
  }
  assert {
    condition     = data.azurerm_public_ip.ingress[0].name == "kubernetes-e5f6"
    error_message = "without the tag, must fall back to the kubernetes- name prefix"
  }
}

run "bring_your_own_idp" {
  command = plan
  variables {
    create_entra_apps = false
  }
  assert {
    condition     = length(module.entra_app) == 0
    error_message = "no Entra apps without create_entra_apps"
  }
}
