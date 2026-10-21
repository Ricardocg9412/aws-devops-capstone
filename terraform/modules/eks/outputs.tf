output "cluster_name" {
  description = "Cluster name for AWS CLI and Kubernetes tooling."
  value       = aws_eks_cluster.this.name
}

output "cluster_arn" {
  description = "Cluster ARN."
  value       = aws_eks_cluster.this.arn
}

output "cluster_endpoint" {
  description = "Private Kubernetes API endpoint; requires private connectivity."
  value       = aws_eks_cluster.this.endpoint
}

output "cluster_certificate_authority_data" {
  description = "Base64 cluster CA certificate, not a private key."
  value       = aws_eks_cluster.this.certificate_authority[0].data
}

output "cluster_security_group_id" {
  description = "EKS-created cluster and managed-node communication SG."
  value       = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
}

output "node_group_name" {
  description = "Managed node group name."
  value       = aws_eks_node_group.this.node_group_name
}

output "control_plane_log_group_name" {
  description = "CloudWatch control-plane log group."
  value       = aws_cloudwatch_log_group.control_plane.name
}

output "vpc_cni_role_arn" {
  description = "Dedicated IRSA role for kube-system/aws-node."
  value       = aws_iam_role.vpc_cni.arn
}
