variable "cluster_name" {
  type = string
}

variable "subnet_ids" {
  type        = set(string)
  description = "Subnet IDs to use for the RDS cluster. Must be in different availability zones."
  validation {
    condition     = length(var.subnet_ids) >= 2
    error_message = "Aurora Serverless requires at least two subnets in different availability zones."
  }
}

variable "postgres_engine_version" {
  type    = string
  default = "17"
}

variable "cluster_deletion_protection" {
  type    = bool
  default = false
}

variable "cluster_instance_count" {
  type = number
}

variable "encryption_key_arn" {
  type = string
}

variable "publicly_accessible" {
  type        = bool
  default     = false
  description = "Assign the cluster instances public IPs so the database is reachable from the internet. Requires subnet_ids to be public subnets (route table with an internet-gateway route)."
}

variable "allowed_cidr_blocks" {
  type        = set(string)
  default     = []
  description = "Extra CIDR blocks allowed inbound on 5432, in addition to the VPC CIDR (which is always allowed so in-VPC clients like EKS keep access). Use with publicly_accessible to expose the database to the internet."
}
