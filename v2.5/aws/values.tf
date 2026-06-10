# Renders a Helm values file per deployment (var.deployment_ids) with
# everything this project knows pre-filled (AWS region, S3 bucket, KMS key,
# the deployment-derived names, and — when the optional database is enabled —
# the PostgreSQL connection); the rest is REPLACE_ME placeholders. Contains
# the database password when create_database is true, so the file is written
# owner-only (0600) and rendered/ must not be committed.

locals {
  postgres = var.create_database ? {
    host     = module.rds[0].cluster_endpoint
    port     = tostring(module.rds[0].cluster_port)
    user     = module.rds[0].cluster_credentials.username
    password = module.rds[0].cluster_credentials.password
    } : {
    host     = "REPLACE_ME"
    port     = "5432"
    user     = "REPLACE_ME"
    password = "REPLACE_ME"
  }
}

resource "local_file" "values" {
  for_each = var.deployment_ids

  filename = "${path.module}/rendered/values-${each.value}.yaml"
  content = templatefile("${path.module}/templates/values.yaml.tftpl", {
    deployment_id     = each.value
    aws_region        = var.region
    s3_bucket_name    = module.prereqs.s3_bucket_name
    kms_key_arn       = module.prereqs.kms_key_arn
    s3_key_prefix     = each.value
    postgres_host     = local.postgres.host
    postgres_port     = local.postgres.port
    postgres_user     = local.postgres.user
    postgres_password = local.postgres.password
    postgres_database = replace(each.value, "-", "_")
  })
  file_permission      = "0600"
  directory_permission = "0755"
}
