variable "namespace" {
  type        = string
  description = "Namespace to create. The deployment name is the namespace."
}

variable "service_account" {
  type        = string
  description = "Service account to create in the namespace, named in the chart's serviceAccount.name."
}

variable "labels" {
  type        = map(string)
  description = "Labels applied to both the namespace and the service account."
  default     = {}
}

variable "service_account_annotations" {
  type        = map(string)
  description = "Annotations on the service account, notably azure.workload.identity/client-id: the identity a Pod carrying the workload identity label assumes."
  default     = {}
}
