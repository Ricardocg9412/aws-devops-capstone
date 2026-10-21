mock_provider "aws" {
  mock_data "aws_partition" {
    defaults = {
      partition  = "aws"
      dns_suffix = "amazonaws.com"
    }
  }
}

variables {
  name_prefix              = "inventory-api-dev"
  github_repository        = "approved-owner/inventory"
  github_branch            = "release"
  github_oidc_provider_arn = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
  tags = {
    Project     = "inventory-api"
    Environment = "dev"
    ManagedBy   = "terraform"
    Owner       = "platform-team"
  }
}

run "ecr_image_tags_are_immutable" {
  command = plan

  assert {
    condition     = aws_ecr_repository.this.image_tag_mutability == "IMMUTABLE"
    error_message = "ECR must reject overwriting existing image tags."
  }

  assert {
    condition = alltrue(flatten([
      for tags in [aws_ecr_repository.this.tags, aws_iam_role.github_actions.tags, aws_iam_role.eks_cluster.tags, aws_iam_role.eks_node.tags] : [
        for key in ["Project", "Environment", "ManagedBy", "Owner"] : try(tags[key] == var.tags[key] && trimspace(tags[key]) != "", false)
      ]
    ]))
    error_message = "The repository and all three IAM roles must preserve every mandatory tag."
  }
}

run "github_oidc_trust_matches_approved_repository_and_branch" {
  command = plan

  assert {
    condition = jsondecode(aws_iam_role.github_actions.assume_role_policy) == {
      Version = "2012-10-17"
      Statement = [{
        Effect    = "Allow"
        Action    = "sts:AssumeRoleWithWebIdentity"
        Principal = { Federated = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com" }
        Condition = {
          StringEquals = {
            "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
            "token.actions.githubusercontent.com:sub" = "repo:approved-owner/inventory:ref:refs/heads/release"
          }
        }
      }]
    }
    error_message = "Trust must permit only the approved provider, audience, exact repository, and release branch, with no extra allow statements or wildcard conditions."
  }
}

run "reject_repository_without_owner" {
  command = plan

  variables {
    github_repository = "inventory"
  }

  expect_failures = [var.github_repository]
}
