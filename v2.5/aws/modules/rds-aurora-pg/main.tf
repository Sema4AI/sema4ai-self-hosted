# Aurora Serverless v2 PostgreSQL. Per-instance databases/users/uuid-ossp are
# NOT created here (the app creates its own database on first start); see the
# root module. Set publicly_accessible (with public subnet_ids) to reach the
# cluster from the internet as well as from inside the VPC.

# Determine the VPC ID from the first subnet.
# All subnets are expected to be in the same VPC.
data "aws_subnet" "first_subnet" {
  id = tolist(var.subnet_ids)[0]
}

data "aws_vpc" "vpc" {
  id = data.aws_subnet.first_subnet.vpc_id
}

resource "random_password" "cluster_admin_password" {
  length  = 32
  special = false
}

resource "aws_db_subnet_group" "postgres" {
  name       = "${var.cluster_name}-subnet-group"
  subnet_ids = var.subnet_ids
}

resource "aws_security_group" "postgres" {
  name        = "${var.cluster_name}-database-security-group"
  description = "Security group for ${var.cluster_name} database"
  vpc_id      = data.aws_vpc.vpc.id

  # Always allow in-VPC clients (EKS pods reach the cluster's private endpoint
  # IP); allowed_cidr_blocks adds any internet sources when publicly_accessible.
  ingress {
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = tolist(toset(concat([data.aws_vpc.vpc.cidr_block], tolist(var.allowed_cidr_blocks))))
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_rds_cluster" "cluster" {
  cluster_identifier      = var.cluster_name
  engine                  = "aurora-postgresql"
  engine_version          = var.postgres_engine_version
  master_username         = "clusteradmin"
  master_password         = random_password.cluster_admin_password.result
  backup_retention_period = 35
  storage_encrypted       = true
  kms_key_id              = var.encryption_key_arn
  db_subnet_group_name    = aws_db_subnet_group.postgres.id
  vpc_security_group_ids  = [aws_security_group.postgres.id]

  deletion_protection = var.cluster_deletion_protection
  skip_final_snapshot = !var.cluster_deletion_protection

  lifecycle {
    ignore_changes = [engine_version]
  }

  serverlessv2_scaling_configuration {
    max_capacity = 10.0
    min_capacity = 0.5
  }
}

resource "aws_rds_cluster_instance" "serverless" {
  count               = var.cluster_instance_count
  identifier          = "${aws_rds_cluster.cluster.id}-instance-${count.index + 1}"
  cluster_identifier  = aws_rds_cluster.cluster.id
  engine              = aws_rds_cluster.cluster.engine
  engine_version      = aws_rds_cluster.cluster.engine_version_actual
  instance_class      = "db.serverless" # Aurora Serverless v2
  publicly_accessible = var.publicly_accessible
}
