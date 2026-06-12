output "kms_key_arn" {
  value       = module.prereqs.kms_key_arn
  description = "Customer-managed KMS key (envelope-encryption KEK + S3 SSE). Critical — see README."
}

output "s3_bucket_name" {
  value = module.prereqs.s3_bucket_name
}

output "app_policy_arn" {
  value       = module.prereqs.app_policy_arn
  description = "IAM policy granting the application S3 + KMS access. Attach it to the application role created by your compute configuration."
}

output "values_files" {
  value       = { for name, file in local_file.values : name => file.filename }
  description = "Rendered Helm values file per deployment. Fill every remaining REPLACE_ME before starting setup in the Sema4 Enterprise portal."
}

output "eks_cluster_name" {
  value       = one(module.eks[*].cluster_name)
  description = "EKS cluster name (null when create_cluster is false). Configure kubectl with: aws eks update-kubeconfig --name <this> --region <region>"
}

output "eks_cluster_endpoint" {
  value = one(module.eks[*].cluster_endpoint)
}

output "app_role_arns" {
  value       = { for d, r in aws_iam_role.app : d => r.arn }
  description = "Per-deployment application IAM role, bound via Pod Identity to namespace <deployment>, service account <deployment>-app."
}

output "rds_endpoint" {
  value       = one(module.rds[*].cluster_endpoint)
  description = "Aurora writer endpoint (null when create_database is false)."
}

output "rds_master_credentials" {
  value       = one(module.rds[*].cluster_credentials)
  sensitive   = true
  description = "Aurora master credentials (null when create_database is false). Read with `terraform output -json rds_master_credentials`."
}
