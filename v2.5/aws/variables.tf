variable "region" {
  type        = string
  description = "AWS region to deploy into."
}

variable "infra_id" {
  type        = string
  description = "Unique identifier for this deployment. Prefixes resource names (KMS alias, S3 bucket, IAM role) and allows multiple deployments in one account."
  validation {
    condition     = length(var.infra_id) >= 1 && length(var.infra_id) <= 16
    error_message = "infra_id must be between 1 and 16 characters."
  }
  validation {
    condition     = regex("^[a-z0-9-]+$", var.infra_id) == var.infra_id
    error_message = "infra_id must contain only lowercase letters, numbers, and hyphens."
  }
}

variable "deployment_ids" {
  type        = set(string)
  description = "Names of the application deployments hosted on this infrastructure. One infrastructure (infra_id) can power multiple deployments. Each name derives that deployment's PostgreSQL database name, S3 key prefix, service account name, and rendered values file."
  default     = ["sema4ai"]
  validation {
    condition     = alltrue([for d in var.deployment_ids : can(regex("^[a-z0-9]([a-z0-9-]{0,38}[a-z0-9])?$", d))])
    error_message = "deployment names must be 1-40 chars, lowercase alphanumeric or hyphens, not starting or ending with a hyphen."
  }
}

# ---------------------------------------------------------------------------
# Optional database.
#
# When enabled, an Aurora Serverless v2 PostgreSQL 17 cluster is created in
# the supplied subnets, encrypted with the shared KMS key, and its connection
# details are pre-filled into the rendered values file. When disabled, bring
# your own PostgreSQL 17 (with the uuid-ossp extension available) and fill the
# postgres fields in the values file yourself.
# ---------------------------------------------------------------------------
variable "create_database" {
  type        = bool
  description = "Create an Aurora Serverless v2 PostgreSQL cluster. Disable to bring your own PostgreSQL 17."
  default     = false
}

variable "database_subnet_ids" {
  type        = set(string)
  description = "Subnet IDs for the Aurora cluster (>= 2 availability zones, same VPC as the EKS nodes so pods can reach it). Required when create_database is true."
  nullable    = true
  default     = null
  validation {
    condition     = !var.create_database || (var.database_subnet_ids != null && length(var.database_subnet_ids) >= 2)
    error_message = "create_database requires database_subnet_ids with at least 2 subnets in different availability zones."
  }
}
