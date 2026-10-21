mock_provider "aws" {
  mock_data "aws_partition" {
    defaults = { partition = "aws", dns_suffix = "amazonaws.com" }
  }
}
run "eks_disabled_by_default" {
  command = plan
  assert {
    condition     = length(module.eks) == 0 && output.eks_cluster_name == null
    error_message = "The local lab must keep EKS disabled by default."
  }
}
run "reject_enable_without_admin" {
  command = plan
  variables { enable_eks = true }
  expect_failures = [var.eks_admin_role_arns]
}
