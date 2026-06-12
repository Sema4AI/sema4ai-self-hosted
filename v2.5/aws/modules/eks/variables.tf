variable "cluster_name" {
  type = string
}

variable "subnet_ids" {
  type        = set(string)
  description = "Subnets for the cluster and its nodes (>= 2 availability zones). Use private subnets with NAT egress."
  validation {
    condition     = length(var.subnet_ids) >= 2
    error_message = "EKS requires at least two subnets in different availability zones."
  }
}

variable "kubernetes_version" {
  type        = string
  description = "Kubernetes version, e.g. \"1.33\". Null means the latest EKS default."
  nullable    = true
  default     = null
}

variable "public_access_cidrs" {
  type        = set(string)
  description = "CIDR blocks allowed to reach the public cluster API endpoint (kubectl/helm). The private endpoint is always enabled for in-VPC access."
  default     = ["0.0.0.0/0"]
}
