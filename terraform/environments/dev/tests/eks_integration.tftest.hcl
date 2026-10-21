mock_provider "aws" {
  mock_data "aws_partition" {
    defaults = { partition = "aws", dns_suffix = "amazonaws.com" }
  }
  mock_data "aws_subnet" {
    defaults = { vpc_id = "vpc-12345678", map_public_ip_on_launch = false }
  }
  mock_resource "aws_vpc" {
    defaults = { id = "vpc-12345678" }
  }
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::123456789012:role/mock-role" }
  }
  mock_resource "aws_launch_template" {
    defaults = { id = "lt-0123456789abcdef0", latest_version = 1 }
  }
  mock_resource "aws_eks_cluster" {
    defaults = {
      identity              = [{ oidc = [{ issuer = "https://oidc.eks.us-east-1.amazonaws.com/id/TEST" }] }]
      certificate_authority = [{ data = "dGVzdA==" }]
    }
  }
}

override_resource {
  target = module.ecr.aws_iam_role.eks_cluster
  values = { arn = "arn:aws:iam::123456789012:role/eks-cluster" }
}
override_resource {
  target = module.ecr.aws_iam_role.eks_node
  values = { arn = "arn:aws:iam::123456789012:role/eks-node" }
}

run "enabled_eks_uses_network_and_iam_outputs" {
  command = apply
  variables {
    enable_eks          = true
    eks_admin_role_arns = ["arn:aws:iam::123456789012:role/platform-admin"]
  }
  assert {
    condition     = output.eks_cluster_name == "inventory-api-dev-eks" && output.eks_node_group_name == "inventory-api-dev-workers" && module.eks[0].cluster_name != null
    error_message = "Enabling EKS must connect the network and separate IAM identities and expose the expected names."
  }
}
