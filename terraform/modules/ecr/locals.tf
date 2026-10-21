data "aws_partition" "current" {}

locals {
  repository_name          = "${var.name_prefix}-ecr"
  subject_repository       = coalesce(var.github_subject_repository, var.github_repository)
  github_subject           = var.github_environment == null ? "repo:${local.subject_repository}:ref:refs/heads/${var.github_branch}" : "repo:${local.subject_repository}:environment:${var.github_environment}"
  github_oidc_provider_arn = var.github_oidc_provider_arn == null ? aws_iam_openid_connect_provider.github[0].arn : var.github_oidc_provider_arn
  node_policy_names        = toset(["AmazonEKSWorkerNodePolicy", "AmazonEC2ContainerRegistryPullOnly"])
}
