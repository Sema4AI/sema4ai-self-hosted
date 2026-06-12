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
  allowed_cidr_blocks     = var.database_allowed_cidr_blocks
  postgres_engine_version = "17"
  cluster_instance_count  = 1
  encryption_key_arn      = module.prereqs.kms_key_arn
}

# ---------------------------------------------------------------------------
# Optional EKS Auto Mode cluster + per-deployment application identity.
# ---------------------------------------------------------------------------
module "eks" {
  source = "./modules/eks"
  count  = var.create_cluster ? 1 : 0

  cluster_name        = var.infra_id
  subnet_ids          = var.cluster_subnet_ids
  kubernetes_version  = var.kubernetes_version
  public_access_cidrs = var.cluster_public_access_cidrs
}

# ELB subnet-discovery tags. The subnets are owned by another Terraform
# configuration (the VPC's), so only these tags are managed here.
resource "aws_ec2_tag" "internal_elb" {
  for_each = var.create_cluster ? var.cluster_subnet_ids : []

  resource_id = each.value
  key         = "kubernetes.io/role/internal-elb"
  value       = "1"
}

resource "aws_ec2_tag" "public_elb" {
  for_each = var.create_cluster && var.external_loadbalancer ? var.cluster_public_subnet_ids : []

  resource_id = each.value
  key         = "kubernetes.io/role/elb"
  value       = "1"
}

# IngressClass manifest for the Auto Mode load-balancing controller; the ALB
# scheme follows external_loadbalancer. Terraform cannot reach into the
# cluster (it may not exist at plan time), so apply the rendered manifest
# once per change: kubectl apply -f rendered/ingressclass-alb.yaml
resource "local_file" "ingressclass" {
  count = var.create_cluster ? 1 : 0

  filename        = "${path.module}/rendered/ingressclass-alb.yaml"
  file_permission = "0644"
  content = templatefile("${path.module}/templates/ingressclass-alb.yaml.tftpl", {
    scheme = var.external_loadbalancer ? "internet-facing" : "internal"
  })
}

# Per-deployment application identity. The namespace and service account it
# binds to are created by the Helm install (--create-namespace,
# serviceAccount.create: true) — Pod Identity needs no annotations on them.
resource "aws_iam_role" "app" {
  for_each = var.create_cluster ? var.deployment_ids : []

  name = "${each.value}-app"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
}

resource "aws_iam_role_policy_attachment" "app" {
  for_each = aws_iam_role.app

  role       = each.value.name
  policy_arn = module.prereqs.app_policy_arn
}

resource "aws_eks_pod_identity_association" "app" {
  for_each = aws_iam_role.app

  cluster_name    = module.eks[0].cluster_name
  namespace       = each.key
  service_account = "${each.key}-app"
  role_arn        = each.value.arn
}
