output "postgres_version" {
  value = aws_rds_cluster.cluster.engine_version
}

output "cluster_endpoint" {
  value       = aws_rds_cluster.cluster.endpoint
  description = "Writer endpoint host (not a secret)."
}

output "cluster_port" {
  value = aws_rds_cluster.cluster.port
}

output "cluster_credentials" {
  value = {
    username = aws_rds_cluster.cluster.master_username
    password = aws_rds_cluster.cluster.master_password
    host     = aws_rds_cluster.cluster.endpoint
    port     = aws_rds_cluster.cluster.port
  }
  sensitive = true
}
