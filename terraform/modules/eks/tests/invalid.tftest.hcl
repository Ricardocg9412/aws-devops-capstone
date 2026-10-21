mock_provider "aws" {
  mock_resource "aws_launch_template" {
    defaults = {
      id             = "lt-0123456789abcdef0"
      latest_version = 1
    }
  }
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::123456789012:role/vpc-cni" }
  }
  mock_data "aws_partition" {
    defaults = {
      partition  = "aws"
      dns_suffix = "amazonaws.com"
    }
  }
  mock_data "aws_subnet" {
    defaults = {
      map_public_ip_on_launch = false
      vpc_id                  = "vpc-12345678"
    }
  }
  mock_resource "aws_eks_cluster" {
    defaults = {
      identity              = [{ oidc = [{ issuer = "https://oidc.eks.us-east-1.amazonaws.com/id/TEST" }] }]
      certificate_authority = [{ data = "dGVzdA==" }]
      endpoint              = "https://example.eks.amazonaws.com"
    }
  }
}
variables {
  name_prefix        = "inventory-api-dev"
  vpc_id             = "vpc-12345678"
  private_subnet_ids = { us-east-1a = "subnet-12345678", us-east-1b = "subnet-87654321" }
  cluster_role_arn   = "arn:aws:iam::123456789012:role/eks-cluster"
  node_role_arn      = "arn:aws:iam::123456789012:role/eks-node"
  admin_role_arns    = ["arn:aws:iam::123456789012:role/platform-admin"]
  admin_access_cidrs = ["10.30.0.0/24"]
  tags               = { Project = "inventory-api", Environment = "dev", ManagedBy = "terraform", Owner = "platform-team" }
}
run "reject_public_ip_subnet" {
  command = plan
  override_data {
    target = data.aws_subnet.worker["us-east-1a"]
    values = { map_public_ip_on_launch = true }
  }
  expect_failures = [aws_eks_node_group.this]
}

run "reject_foreign_vpc" {
  command = plan
  override_data {
    target = data.aws_subnet.worker["us-east-1a"]
    values = { vpc_id = "vpc-87654321" }
  }
  expect_failures = [aws_eks_node_group.this]
}

run "reject_unsupported_version" {
  command = plan
  variables {
    cluster_version = "1.27"
  }
  expect_failures = [var.cluster_version]
}

run "reject_invalid_scaling" {
  command = plan
  variables {
    node_scaling = { "min" : 2, "desired" : 1, "max" : 3 }
  }
  expect_failures = [var.node_scaling]
}

run "reject_no_admin" {
  command = plan
  variables {
    admin_role_arns = []
  }
  expect_failures = [var.admin_role_arns]
}

run "reject_session_admin" {
  command = plan
  variables {
    admin_role_arns = ["arn:aws:sts::123456789012:assumed-role/admin/session"]
  }
  expect_failures = [var.admin_role_arns]
}

run "reject_world_admin_ingress" {
  command = plan
  variables {
    admin_access_cidrs = ["0.0.0.0/0"]
  }
  expect_failures = [var.admin_access_cidrs]
}

run "reject_ami_id" {
  command = plan
  variables {
    node_ami_release_version = "ami-0123456789abcdef0"
  }
  expect_failures = [var.node_ami_release_version]
}

run "reject_single_subnet" {
  command = plan
  variables {
    private_subnet_ids = { "us-east-1a" : "subnet-12345678" }
  }
  expect_failures = [var.private_subnet_ids]
}
