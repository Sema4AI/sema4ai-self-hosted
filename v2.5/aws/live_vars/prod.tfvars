# =============================================================================
# Sema4.ai self-hosted — prod environment (NOT YET APPLIED)
# Account 027089197438 (MediaMint), mediamint-prod VPC
# (vpc-0daa5ffb2fd6d9af7, 10.102.0.0/16).
# =============================================================================
region   = "us-east-1"
infra_id = "mm-sema4"

deployment_ids = ["prod"]

create_database = true
database_subnet_ids = [
  "subnet-0e41b5907e807b0bc", # 10.102.11.0/24  us-east-1a (private)
  "subnet-099ef888ac770d7ab", # 10.102.12.0/24  us-east-1b (private)
  "subnet-0edc73fcdbae24a04", # 10.102.13.0/24  us-east-1c (private)
]
