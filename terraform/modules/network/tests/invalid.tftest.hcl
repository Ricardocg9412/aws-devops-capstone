mock_provider "aws" {}

variables {
  name_prefix        = "inventory-api-dev"
  vpc_cidr           = "10.20.0.0/16"
  availability_zones = ["us-east-1a", "us-east-1b"]
  tags = {
    Project     = "inventory-api"
    Environment = "dev"
    ManagedBy   = "terraform"
    Owner       = "platform-team"
  }
}

run "invalid_cidr" {
  command = plan
  variables {
    vpc_cidr = "bad-cidr"
  }
  expect_failures = [var.vpc_cidr]
}

run "host_bits" {
  command = plan
  variables {
    vpc_cidr = "10.20.1.5/16"
  }
  expect_failures = [var.vpc_cidr]
}

run "ipv6" {
  command = plan
  variables {
    vpc_cidr = "fd00::/16"
  }
  expect_failures = [var.vpc_cidr]
}

run "public_cidr" {
  command = plan
  variables {
    vpc_cidr = "8.8.0.0/16"
  }
  expect_failures = [var.vpc_cidr]
}

run "invalid_az_count" {
  command = plan
  variables {
    availability_zones = ["us-east-1a"]
  }
  expect_failures = [var.availability_zones]
}

run "duplicate_azs" {
  command = plan
  variables {
    availability_zones = ["us-east-1a", "us-east-1a"]
  }
  expect_failures = [var.availability_zones]
}

run "blank_owner" {
  command = plan
  variables {
    tags = { "Project" : "test", "Environment" : "dev", "ManagedBy" : "terraform", "Owner" : "" }
  }
  expect_failures = [var.tags]
}

