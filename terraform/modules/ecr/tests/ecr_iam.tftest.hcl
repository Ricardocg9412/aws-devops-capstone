mock_provider "aws" {
  mock_data "aws_partition" {
    defaults = {
      partition  = "aws"
      dns_suffix = "amazonaws.com"
    }
  }
}

variables {
  name_prefix       = "inventory-api-dev"
  github_repository = "example/inventory"
  tags = {
    Project     = "inventory-api"
    Environment = "dev"
    ManagedBy   = "terraform"
    Owner       = "platform-team"
  }
}

run "secure_defaults" {
  command = apply

  assert {
    condition = aws_ecr_repository.this.name == "inventory-api-dev-ecr" && aws_ecr_repository.this.image_tag_mutability == "IMMUTABLE" && !aws_ecr_repository.this.force_delete && alltrue([
      for config in aws_ecr_repository.this.image_scanning_configuration : config.scan_on_push
      ]) && alltrue([
      for config in aws_ecr_repository.this.encryption_configuration : config.encryption_type == "KMS"
    ]) && aws_ecr_repository.this.tags.Environment == "dev"
    error_message = "Repository must have consistent naming/tags, immutable tags, KMS encryption, scan-on-push, and safe deletion."
  }
  assert {
    condition     = jsondecode(aws_ecr_lifecycle_policy.this.policy).rules[0].selection.tagStatus == "untagged" && jsondecode(aws_ecr_lifecycle_policy.this.policy).rules[0].selection.countNumber == 7 && jsondecode(aws_ecr_lifecycle_policy.this.policy).rules[1].selection.tagPatternList[0] == "sha-*" && jsondecode(aws_ecr_lifecycle_policy.this.policy).rules[1].selection.countNumber == 30
    error_message = "Lifecycle rules must expire old untagged images and bound SHA-tagged image retention."
  }
  assert {
    condition     = jsondecode(aws_iam_role.github_actions.assume_role_policy).Statement[0].Action == "sts:AssumeRoleWithWebIdentity" && jsondecode(aws_iam_role.github_actions.assume_role_policy).Statement[0].Principal.Federated == aws_iam_openid_connect_provider.github[0].arn && jsondecode(aws_iam_role.github_actions.assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:aud"] == "sts.amazonaws.com" && jsondecode(aws_iam_role.github_actions.assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:sub"] == "repo:example/inventory:ref:refs/heads/main" && !contains(keys(jsondecode(aws_iam_role.github_actions.assume_role_policy).Statement[0].Condition), "StringLike")
    error_message = "Publisher trust must use exact repository/branch and audience matching."
  }
  assert {
    condition     = jsondecode(aws_iam_role_policy.github_publish.policy).Statement[0].Resource == "*" && jsondecode(aws_iam_role_policy.github_publish.policy).Statement[0].Action == ["ecr:GetAuthorizationToken"] && jsondecode(aws_iam_role_policy.github_publish.policy).Statement[1].Resource == aws_ecr_repository.this.arn && toset(jsondecode(aws_iam_role_policy.github_publish.policy).Statement[1].Action) == toset(["ecr:BatchCheckLayerAvailability", "ecr:InitiateLayerUpload", "ecr:UploadLayerPart", "ecr:CompleteLayerUpload", "ecr:PutImage", "ecr:BatchGetImage"])
    error_message = "Only token retrieval may use wildcard resources; publishing actions must target this repository."
  }
  assert {
    condition     = jsondecode(aws_iam_role.eks_cluster.assume_role_policy).Statement[0].Principal.Service == "eks.amazonaws.com" && jsondecode(aws_iam_role.eks_node.assume_role_policy).Statement[0].Principal.Service == "ec2.amazonaws.com" && aws_iam_role.eks_cluster.name != aws_iam_role.eks_node.name && aws_iam_role.github_actions.name != aws_iam_role.eks_node.name && aws_iam_role_policy_attachment.eks_cluster.policy_arn == "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy" && toset([for item in aws_iam_role_policy_attachment.eks_node : item.policy_arn]) == toset(["arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy", "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPullOnly"])
    error_message = "Cluster, node, and publisher identities must be distinct with correct EKS policy attachments."
  }
}

run "protected_environment_and_existing_provider" {
  command = apply
  variables {
    github_environment       = "production"
    github_oidc_provider_arn = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
    untagged_expiration_days = 14
    retained_sha_images      = 50
  }
  assert {
    condition     = length(aws_iam_openid_connect_provider.github) == 0 && jsondecode(aws_iam_role.github_actions.assume_role_policy).Statement[0].Principal.Federated == var.github_oidc_provider_arn && jsondecode(aws_iam_role.github_actions.assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:sub"] == "repo:example/inventory:environment:production"
    error_message = "Environment mode must use an exact protected environment and reuse the existing provider."
  }
  assert {
    condition     = jsondecode(aws_ecr_lifecycle_policy.this.policy).rules[0].selection.countNumber == 14 && jsondecode(aws_ecr_lifecycle_policy.this.policy).rules[1].selection.countNumber == 50
    error_message = "Retention must be configurable."
  }
}

run "immutable_repository_identity" {
  command = plan
  variables {
    github_subject_repository = "example@123/inventory@456"
    github_branch             = "release"
  }
  assert {
    condition     = output.github_oidc_subject == "repo:example@123/inventory@456:ref:refs/heads/release"
    error_message = "Immutable GitHub owner/repository IDs must be preserved in the exact subject."
  }
}
