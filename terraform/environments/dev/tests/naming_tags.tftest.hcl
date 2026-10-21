mock_provider "aws" {}

run "default_names_and_tags" {
  command = plan

  assert {
    condition     = local.name_prefix == "inventory-api-dev"
    error_message = "The default naming prefix must combine project and environment."
  }

  assert {
    condition = tomap(local.resource_tags) == tomap({
      Project     = "inventory-api"
      Environment = "dev"
      ManagedBy   = "terraform"
      Owner       = "platform-team"
    })
    error_message = "Default mandatory tags must be consistent."
  }
}

run "prod_normalizes_tags_and_preserves_extras" {
  command = plan

  variables {
    project_name = "another-api"
    environment  = "prod"
    common_tags = {
      Project     = "outdated-project"
      Environment = "dev"
      ManagedBy   = "manual"
      Owner       = " application-team "
      CostCenter  = "engineering"
    }
  }

  assert {
    condition     = local.name_prefix == "another-api-prod"
    error_message = "Names must follow the selected project and environment."
  }

  assert {
    condition = tomap(local.resource_tags) == tomap({
      Project     = "another-api"
      Environment = "prod"
      ManagedBy   = "terraform"
      Owner       = "application-team"
      CostCenter  = "engineering"
    })
    error_message = "Identity tags must be normalized and optional tags preserved."
  }
}

run "reject_missing_owner" {
  command = plan

  variables {
    common_tags = {
      Project     = "inventory-api"
      Environment = "dev"
      ManagedBy   = "terraform"
    }
  }

  expect_failures = [var.common_tags]
}

run "reject_blank_owner" {
  command = plan

  variables {
    common_tags = {
      Project     = "inventory-api"
      Environment = "dev"
      ManagedBy   = "terraform"
      Owner       = "   "
    }
  }

  expect_failures = [var.common_tags]
}

run "reject_null_owner" {
  command = plan

  variables {
    common_tags = {
      Project     = "inventory-api"
      Environment = "dev"
      ManagedBy   = "terraform"
      Owner       = null
    }
  }

  expect_failures = [var.common_tags]
}

run "reject_invalid_project_name" {
  command = plan

  variables {
    project_name = "Invalid Project"
  }

  expect_failures = [var.project_name]
}
