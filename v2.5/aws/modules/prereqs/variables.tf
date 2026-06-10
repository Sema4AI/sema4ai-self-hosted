variable "infra_id" {
  type        = string
  description = "Name prefix for the prereq resources (KMS alias, S3 bucket, IAM policy)."
}

variable "tags" {
  type    = map(string)
  default = {}
}
