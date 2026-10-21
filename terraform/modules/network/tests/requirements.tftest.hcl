mock_provider "aws" {}

variables {
  name_prefix        = "inventory-api-dev"
  vpc_cidr           = "10.42.0.0/16"
  availability_zones = ["us-east-1a", "us-east-1b"]
  tags = {
    Project     = "inventory-api"
    Environment = "dev"
    ManagedBy   = "terraform"
    Owner       = "platform-team"
  }
}

run "vpc_cidr_matches_configured_value" {
  command = plan

  assert {
    condition     = aws_vpc.this.cidr_block == var.vpc_cidr && output.vpc_cidr == "10.42.0.0/16"
    error_message = "The VPC and its output must use the configured CIDR, including a nondefault value."
  }
}

run "exactly_two_public_and_two_private_subnets" {
  command = plan

  assert {
    condition     = length(aws_subnet.public) == 2 && length(aws_subnet.private) == 2
    error_message = "The network must define exactly two public and two private subnets."
  }
}

run "private_subnets_disable_public_ip_assignment" {
  command = plan

  assert {
    condition     = length(aws_subnet.private) == 2 && alltrue([for subnet in aws_subnet.private : subnet.map_public_ip_on_launch == false])
    error_message = "Every private subnet must explicitly disable automatic public IP assignment."
  }
}

run "mandatory_tags_on_all_tagged_network_resources" {
  command = plan

  variables {
    enable_nat_gateway = true
  }

  assert {
    condition = alltrue(flatten([
      for tags in concat(
        [aws_vpc.this.tags, aws_internet_gateway.this.tags, aws_route_table.public.tags, aws_default_security_group.this.tags, aws_security_group.workload.tags],
        [for subnet in aws_subnet.public : subnet.tags],
        [for subnet in aws_subnet.private : subnet.tags],
        [for table in aws_route_table.private : table.tags],
        [for gateway in aws_nat_gateway.this : gateway.tags],
        [for address in aws_eip.nat : address.tags]
        ) : [
        for key in ["Project", "Environment", "ManagedBy", "Owner"] : try(tags[key] == var.tags[key] && trimspace(tags[key]) != "", false)
      ]
    ]))
    error_message = "Every taggable network resource, including optional NAT resources, must retain all four mandatory tags."
  }
}

run "reject_noncanonical_cidr_prefix" {
  command = plan

  variables {
    vpc_cidr = "10.42.0.0/016"
  }

  expect_failures = [var.vpc_cidr]
}
