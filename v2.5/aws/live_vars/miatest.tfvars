# =============================================================================
# Sema4.ai self-hosted — miatest environment
# Account 027089197438 (MediaMint), mediamint-testing VPC
# (vpc-0a276fbf808d409c8, 10.105.0.0/16).
# =============================================================================
region   = "us-east-1"
infra_id = "mm-sema4-test"

deployment_ids = ["miatest"]

create_cluster     = true
cluster_subnet_ids = [
  "subnet-02bb51e3f20cc8fe2", # 10.105.11.0/24  us-east-1a (private)
  "subnet-0342246cda3aa92aa", # 10.105.12.0/24  us-east-1b (private)
  "subnet-072180b28152f2c39", # 10.105.13.0/24  us-east-1c (private)
]

# Internet-facing ALB (login still gated by OIDC). After changing, re-apply
# rendered/ingressclass-alb.yaml.
external_loadbalancer = true
cluster_public_subnet_ids = [
  "subnet-04cf18543e31f6965", # 10.105.1.0/24  us-east-1a (public)
  "subnet-0bc4e19c807fefda3", # 10.105.2.0/24  us-east-1b (public)
  "subnet-06cc4846b7dc7a85e", # 10.105.3.0/24  us-east-1c (public)
]

create_database = true

# Peered ACE VPC (10.137.0.0/16, pcx-0b6faa05f5987fd8a) hosting the SSM
# bastion i-099b608325ebaeb2d — same database access path as
# mediamint-testing-db.
database_allowed_cidr_blocks = ["10.137.0.0/16"]

database_subnet_ids = [
  "subnet-02bb51e3f20cc8fe2", # 10.105.11.0/24  us-east-1a
  "subnet-0342246cda3aa92aa", # 10.105.12.0/24  us-east-1b
  "subnet-072180b28152f2c39", # 10.105.13.0/24  us-east-1c
]
