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

run "wildcard_repository" {
  command = plan
  variables {
    github_repository = "*/*"
  }
  expect_failures = [var.github_repository]
}

run "wildcard_branch" {
  command = plan
  variables {
    github_branch = "*"
  }
  expect_failures = [var.github_branch]
}

run "empty_branch" {
  command = plan
  variables {
    github_branch = ""
  }
  expect_failures = [var.github_branch]
}

run "wildcard_environment" {
  command = plan
  variables {
    github_environment = "*"
  }
  expect_failures = [var.github_environment]
}

run "empty_environment" {
  command = plan
  variables {
    github_environment = ""
  }
  expect_failures = [var.github_environment]
}

run "wrong_immutable_repository" {
  command = plan
  variables {
    github_subject_repository = "attacker@123/other@456"
  }
  expect_failures = [var.github_subject_repository]
}

run "wildcard_subject_repository" {
  command = plan
  variables {
    github_subject_repository = "example@123/*"
  }
  expect_failures = [var.github_subject_repository]
}

run "wrong_provider" {
  command = plan
  variables {
    github_oidc_provider_arn = "arn:aws:iam::123456789012:oidc-provider/attacker.example"
  }
  expect_failures = [var.github_oidc_provider_arn]
}

run "zero_retention" {
  command = plan
  variables {
    retained_sha_images = 0
  }
  expect_failures = [var.retained_sha_images]
}

run "fractional_retention" {
  command = plan
  variables {
    untagged_expiration_days = 1.5
  }
  expect_failures = [var.untagged_expiration_days]
}

run "missing_tags" {
  command = plan
  variables {
    tags = { "Owner" : "team" }
  }
  expect_failures = [var.tags]
}

