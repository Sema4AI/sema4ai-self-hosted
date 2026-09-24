terraform {
  required_version = ">= 1.13"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.45"
    }
    # Only for the cluster's Gateway API settings (modules/aks), which the
    # azurerm provider cannot yet express.
    azapi = {
      source  = "Azure/azapi"
      version = "~> 2.12"
    }
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 3.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.1"
    }
  }

  # State backend intentionally not configured — add your organization's
  # standard backend (e.g. azurerm) here. With no backend, state is stored
  # locally in terraform.tfstate, and it contains every generated secret: the
  # PostgreSQL admin and role passwords, the Entra ID client secrets, and each
  # deployment's two encryption keys. Protect it accordingly.
}

provider "azurerm" {
  features {}

  subscription_id = var.subscription_id
}

provider "azapi" {
  subscription_id = var.subscription_id
}

provider "azuread" {
  # Tenant is inherited from the Azure CLI session that runs `terraform apply`.
}

# Configured from the AKS cluster this same configuration creates, with the
# cluster's local admin certificate — no `az aks get-credentials` and no Entra
# login during apply. It owns the only in-cluster resources Terraform is
# responsible for: the cluster's Gateway, and each deployment's namespace and
# service account. Everything else in the cluster (the sandbox runtime, the
# application releases and the HTTPRoutes they render) is installed by the
# operator with helm.
#
# The Gateway is a kubernetes_manifest resource, which reads the cluster and
# the Gateway API CRDs at plan time, so a new cluster is applied with
# `-target=module.aks` first (README.md, step 1).
#
# The API server endpoint must be reachable from wherever Terraform runs; the
# cluster is created with a public endpoint.
provider "kubernetes" {
  host                   = module.aks.kube_config.host
  client_certificate     = base64decode(module.aks.kube_config.client_certificate)
  client_key             = base64decode(module.aks.kube_config.client_key)
  cluster_ca_certificate = base64decode(module.aks.kube_config.cluster_ca_certificate)
}
