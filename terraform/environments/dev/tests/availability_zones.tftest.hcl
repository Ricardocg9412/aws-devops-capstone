mock_provider "aws" {}
run "reject_wrong_region" {
  command = plan
  variables {
    aws_region = "us-west-2"
  }
  expect_failures = [var.availability_zones]
}
run "accept_matching_region" {
  command = plan
  variables {
    aws_region         = "us-west-2"
    availability_zones = ["us-west-2a", "us-west-2b"]
  }
}
