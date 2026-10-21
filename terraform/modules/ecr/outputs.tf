output "repository_name" {
  description = "ECR repository name."
  value       = aws_ecr_repository.this.name
}

output "repository_arn" {
  description = "ECR repository ARN."
  value       = aws_ecr_repository.this.arn
}

output "repository_url" {
  description = "ECR image publishing URL."
  value       = aws_ecr_repository.this.repository_url
}

output "github_actions_role_arn" {
  description = "GitHub publishing role ARN for the workflow."
  value       = aws_iam_role.github_actions.arn
  depends_on  = [aws_iam_role_policy.github_publish]
}

output "github_oidc_provider_arn" {
  description = "Created or reused GitHub OIDC provider ARN."
  value       = local.github_oidc_provider_arn
}

output "github_oidc_subject" {
  description = "Exact trusted GitHub OIDC subject."
  value       = local.github_subject
}

output "eks_cluster_role_arn" {
  description = "EKS control-plane role ARN, ready after its policy attachment."
  value       = aws_iam_role.eks_cluster.arn
  depends_on  = [aws_iam_role_policy_attachment.eks_cluster]
}

output "eks_node_role_arn" {
  description = "EKS managed-node role ARN, ready after its policy attachments."
  value       = aws_iam_role.eks_node.arn
  depends_on  = [aws_iam_role_policy_attachment.eks_node]
}
