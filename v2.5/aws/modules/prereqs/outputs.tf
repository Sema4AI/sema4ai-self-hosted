output "kms_key_arn" {
  value = aws_kms_key.main.arn
}

output "s3_bucket_name" {
  value = aws_s3_bucket.main.bucket
}

output "app_policy_arn" {
  value       = aws_iam_policy.app.arn
  description = "IAM policy granting the application S3 + KMS access. Attach to the application role created by your compute configuration."
}

output "app_policy_name" {
  value = aws_iam_policy.app.name
}
