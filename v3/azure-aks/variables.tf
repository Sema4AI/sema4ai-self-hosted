variable "subscription_id" {
  type        = string
  description = "The Azure subscription to create the resources in."
}

variable "infra_id" {
  type        = string
  description = "A unique identifier for this infrastructure, used in the name of every resource it creates (e.g. s4aiprod). Several Azure names derived from it are globally unique (the storage account, the Key Vault, the PostgreSQL server), so pick something specific to your organization."
  validation {
    condition     = can(regex("^[a-z0-9]+$", var.infra_id)) && length(var.infra_id) <= 15
    error_message = "infra_id must be lowercase alphanumeric characters only, at most 15 characters."
  }
}

variable "location" {
  type        = string
  description = "The Azure region to provision the infrastructure in (e.g. 'East US 2', 'West Europe'). It must offer the node VM size in an availability zone, and an AKS version of 1.36 or newer."
}

variable "deployment_ids" {
  type        = set(string)
  description = "Names of the application deployments hosted on this infrastructure. Each name is that deployment's Kubernetes namespace and Helm release name, and derives its service account (<name>-app), database and roles, blob key prefix, Key Vault key, Front Door endpoint, Entra ID app registration, and rendered values file."
  default     = ["sema4ai"]
  validation {
    condition     = alltrue([for d in var.deployment_ids : can(regex("^[a-z]([a-z0-9-]{0,18}[a-z0-9])?$", d))])
    error_message = "deployment names must be 1-20 chars, lowercase alphanumeric or hyphens, starting with a letter and not ending with a hyphen. They double as PostgreSQL identifiers, and the 20-char ceiling keeps the chart's derived resource names inside Kubernetes' 63-char limit."
  }
}

variable "create_entra_apps" {
  type        = bool
  description = "Create an Entra ID app registration per deployment and render its client ID and secret into the values file. Requires the identity running Terraform to hold Microsoft Graph rights to create app registrations (Application.ReadWrite.OwnedBy, or the Application Administrator / Cloud Application Administrator role). Set false to bring your own identity provider: the rendered values then leave the three OIDC fields as REPLACE_ME."
  default     = true
}

# ---------------------------------------------------------------------------
# Network
# ---------------------------------------------------------------------------

variable "vnet_address_space" {
  type        = string
  description = "Address space of the virtual network. Change it if it would overlap a network you peer with."
  default     = "10.0.0.0/16"
}

variable "aks_subnet_prefix" {
  type        = string
  description = "Node subnet of the cluster, inside vnet_address_space. Only node IPs come from it (Azure CNI Overlay), so it can stay small."
  default     = "10.0.32.0/24"
}

variable "db_subnet_prefix" {
  type        = string
  description = "Subnet delegated to PostgreSQL Flexible Server, inside vnet_address_space. It must hold nothing else."
  default     = "10.0.2.0/24"
}

# ---------------------------------------------------------------------------
# Cluster
# ---------------------------------------------------------------------------

variable "kubernetes_version" {
  type        = string
  description = "AKS Kubernetes version, minor only (AKS picks the patch). The application requires 1.36 or newer. Confirm the version is offered in your region with `az aks get-versions --location <location> --output table`."
  default     = "1.36"
}

# The node is constrained in three ways, all of them properties of the VM
# size, so a wrong choice is a node pool replacement rather than a values-file
# edit:
#
#   * 32 vCPU / 128 GiB — the node carries the whole application AND every
#     concurrent sandbox run; sandbox concurrency is a fixed runner pool, so
#     the node is the hard ceiling on how much agent work can run at once.
#   * x86_64 — there is no arm64 build.
#   * nested virtualization — the sandbox starts a microVM per run and needs
#     /dev/kvm on the node. On Azure that is a property of the VM size, not a
#     node pool setting.
#
# Standard_D32s_v5 (Intel) is exactly that shape and supports nested
# virtualization. If you pick another size, confirm both in the Azure
# documentation, and run k8s/kvm-check.yaml before installing the sandbox
# runtime.
variable "node_vm_size" {
  type        = string
  description = "VM size of the node pool. Must be x86_64, support nested virtualization, and provide 32 vCPU / 128 GiB."
  default     = "Standard_D32s_v5"
}

variable "node_os_disk_size_gb" {
  type        = number
  description = "OS disk of the node, in GiB. Holds the node image and every container image the cluster pulls; the application images and the sandbox runtime are large, so raise it if you run several deployments."
  default     = 128
}

# The data root is a zonal disk created in the node's zone. A single zone is
# the supported shape (the node is a single point of failure either way).
# Changing this replaces the node.
variable "node_zones" {
  type        = list(string)
  description = "Availability zone of the node pool, as a one-element list."
  default     = ["1"]
  validation {
    condition     = length(var.node_zones) == 1
    error_message = "Pin the node pool to exactly one availability zone."
  }
}

# ---------------------------------------------------------------------------
# PostgreSQL
#
# One Flexible Server is shared by every deployment on the cluster, each with
# its own database and roles. A deployment opens several pools (the API, the
# worker, the semantic query runner, the VFS and the sandbox each hold their
# own), so both the SKU and max_connections scale with the number of
# deployments rather than with traffic.
# ---------------------------------------------------------------------------

variable "postgres_sku_name" {
  type        = string
  description = "Flexible Server compute SKU. GP_Standard_D4s_v3 (4 vCPU / 16 GiB) is the smallest sensible size for one deployment; the burstable B-series is too small."
  default     = "GP_Standard_D4s_v3"
}

variable "postgres_storage_mb" {
  type        = number
  description = "Flexible Server storage in MB. Storage can only ever grow."
  default     = 131072
}

variable "postgres_storage_tier" {
  type        = string
  description = "Flexible Server storage performance tier (P4/P6/P10/...). Must be one the chosen storage_mb allows."
  default     = "P10"
}

variable "postgres_max_connections" {
  type        = number
  description = "max_connections server parameter. Must fit the chosen SKU. NOTE: changing it restarts the server."
  default     = 500
}

# ---------------------------------------------------------------------------
# Blob storage and Key Vault
# ---------------------------------------------------------------------------

variable "blob_replication_type" {
  type        = string
  description = "Replication of the storage account holding the blob store, which is the system of record for workspace files. LRS keeps a trial cheap; use ZRS or GZRS for production."
  default     = "LRS"
}

variable "key_vault_purge_protection" {
  type        = bool
  description = "Enable purge protection on the Key Vault holding each deployment's secrets key. Irreversible once on, and it keeps a destroyed vault reserved for the soft-delete window, so `terraform destroy` followed by a re-apply fails on the name. Off by default so a trial can be torn down; turn it on for production (see README.md)."
  default     = false
}
