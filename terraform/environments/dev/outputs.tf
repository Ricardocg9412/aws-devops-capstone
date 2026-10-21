output "vpc_id" {
  description = "Network VPC ID."
  value       = module.network.vpc_id
}

output "vpc_cidr" {
  description = "Allocated VPC CIDR."
  value       = module.network.vpc_cidr
}

output "public_subnet_ids" {
  description = "Public subnet IDs keyed by AZ."
  value       = module.network.public_subnet_ids
}

output "private_subnet_ids" {
  description = "Private subnet IDs keyed by AZ."
  value       = module.network.private_subnet_ids
}

output "public_subnet_cidrs" {
  description = "Public subnet CIDRs keyed by AZ."
  value       = module.network.public_subnet_cidrs
}

output "private_subnet_cidrs" {
  description = "Private subnet CIDRs keyed by AZ."
  value       = module.network.private_subnet_cidrs
}

output "public_route_table_id" {
  description = "Public route table ID."
  value       = module.network.public_route_table_id
}

output "private_route_table_ids" {
  description = "Private route table IDs keyed by AZ."
  value       = module.network.private_route_table_ids
}

output "nat_gateway_ids" {
  description = "NAT Gateway IDs keyed by AZ; empty when disabled."
  value       = module.network.nat_gateway_ids
}

output "workload_security_group_id" {
  description = "Baseline workload SG ID."
  value       = module.network.workload_security_group_id
}

output "repository_name" {
  description = "ECR repository name."
  value       = module.ecr.repository_name
}

output "repository_arn" {
  description = "ECR repository ARN."
  value       = module.ecr.repository_arn
}

output "repository_url" {
  description = "ECR image publishing URL."
  value       = module.ecr.repository_url
}

output "github_actions_role_arn" {
  description = "GitHub publishing role ARN for the workflow."
  value       = module.ecr.github_actions_role_arn
}

output "github_oidc_provider_arn" {
  description = "Created or reused GitHub OIDC provider ARN."
  value       = module.ecr.github_oidc_provider_arn
}

output "github_oidc_subject" {
  description = "Exact trusted GitHub OIDC subject."
  value       = module.ecr.github_oidc_subject
}

output "eks_cluster_role_arn" {
  description = "EKS control-plane role ARN, ready after its policy attachment."
  value       = module.ecr.eks_cluster_role_arn
}

output "eks_node_role_arn" {
  description = "EKS managed-node role ARN, ready after its policy attachments."
  value       = module.ecr.eks_node_role_arn
}

output "eks_cluster_name" {
  description = "EKS cluster name; null when disabled."
  value       = try(module.eks[0].cluster_name, null)
}

output "eks_cluster_endpoint" {
  description = "EKS cluster endpoint; null when disabled."
  value       = try(module.eks[0].cluster_endpoint, null)
}

output "eks_node_group_name" {
  description = "EKS node group name; null when disabled."
  value       = try(module.eks[0].node_group_name, null)
}

output "eks_control_plane_log_group_name" {
  description = "EKS control plane log group name; null when disabled."
  value       = try(module.eks[0].control_plane_log_group_name, null)
}
