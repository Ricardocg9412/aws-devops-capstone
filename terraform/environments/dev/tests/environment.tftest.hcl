mock_provider "aws" {}

run "accept_dev" {
  command = plan

  variables {
    environment = "dev"
  }
}

run "accept_prod" {
  command = plan

  variables {
    environment = "prod"
  }
}

run "reject_staging" {
  command = plan

  variables {
    environment = "staging"
  }

  expect_failures = [var.environment]
}

run "reject_uppercase" {
  command = plan

  variables {
    environment = "DEV"
  }

  expect_failures = [var.environment]
}

run "reject_empty" {
  command = plan

  variables {
    environment = ""
  }

  expect_failures = [var.environment]
}
