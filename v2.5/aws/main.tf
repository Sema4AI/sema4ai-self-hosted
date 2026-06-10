# AWS data-plane prerequisites for Sema4.ai self-hosted: KMS key + S3 bucket +
# the IAM policy granting the application access to them, plus an optional
# Aurora PostgreSQL cluster. Only resources generic to hosting on AWS live
# here — anything compute-specific (EKS cluster, VMs, Fargate, networking,
# ingress, and the application IAM role with its platform-specific trust
# policy) is deployed as part of the compute configuration; see the
# shared-responsibility section in README.md.

module "prereqs" {
  source = "./modules/prereqs"

  infra_id = var.infra_id
}

module "rds" {
  source = "./modules/rds-aurora-pg"
  count  = var.create_database ? 1 : 0

  cluster_name            = var.infra_id
  subnet_ids              = var.database_subnet_ids
  postgres_engine_version = "17"
  cluster_instance_count  = 1
  encryption_key_arn      = module.prereqs.kms_key_arn
}
