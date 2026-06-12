output "cluster_name" {
  value = aws_eks_cluster.main.name
}

output "cluster_arn" {
  value = aws_eks_cluster.main.arn
}

output "cluster_endpoint" {
  value = aws_eks_cluster.main.endpoint
}

output "cluster_security_group_id" {
  description = "EKS-managed cluster security group (nodes and control plane)."
  value       = aws_eks_cluster.main.vpc_config[0].cluster_security_group_id
}
