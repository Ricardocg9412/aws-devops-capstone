mock_provider "aws" {
  mock_data "aws_partition" {
    defaults = {
      partition  = "aws"
      dns_suffix = "amazonaws.com"
    }
  }
}

run "accept_default_prefix" {
  command = plan

  variables {
    vpc_cidr = "10.20.0.0/16"
  }

  assert {
    condition     = output.vpc_cidr == var.vpc_cidr
    error_message = "Accepted CIDR must be preserved in the root output."
  }
}

run "accept_smallest_prefix" {
  command = plan

  variables {
    vpc_cidr = "10.20.1.0/24"
  }

  assert {
    condition     = output.vpc_cidr == var.vpc_cidr
    error_message = "Accepted CIDR must be preserved in the root output."
  }
}

run "accept_private_172_start" {
  command = plan

  variables {
    vpc_cidr = "172.16.0.0/20"
  }

  assert {
    condition     = output.vpc_cidr == var.vpc_cidr
    error_message = "Accepted CIDR must be preserved in the root output."
  }
}

run "accept_private_172_end" {
  command = plan

  variables {
    vpc_cidr = "172.31.0.0/16"
  }

  assert {
    condition     = output.vpc_cidr == var.vpc_cidr
    error_message = "Accepted CIDR must be preserved in the root output."
  }
}

run "accept_private_192" {
  command = plan

  variables {
    vpc_cidr = "192.168.1.0/24"
  }

  assert {
    condition     = output.vpc_cidr == var.vpc_cidr
    error_message = "Accepted CIDR must be preserved in the root output."
  }
}

run "reject_malformed" {
  command = plan

  variables {
    vpc_cidr = "not-a-cidr"
  }

  expect_failures = [var.vpc_cidr]
}

run "reject_invalid_octet" {
  command = plan

  variables {
    vpc_cidr = "10.256.0.0/16"
  }

  expect_failures = [var.vpc_cidr]
}

run "reject_missing_prefix" {
  command = plan

  variables {
    vpc_cidr = "10.20.0.0"
  }

  expect_failures = [var.vpc_cidr]
}

run "reject_invalid_prefix" {
  command = plan

  variables {
    vpc_cidr = "10.20.0.0/33"
  }

  expect_failures = [var.vpc_cidr]
}

run "reject_host_bits" {
  command = plan

  variables {
    vpc_cidr = "10.20.0.5/16"
  }

  expect_failures = [var.vpc_cidr]
}

run "reject_ipv6" {
  command = plan

  variables {
    vpc_cidr = "fd00::/16"
  }

  expect_failures = [var.vpc_cidr]
}

run "reject_public" {
  command = plan

  variables {
    vpc_cidr = "8.8.0.0/16"
  }

  expect_failures = [var.vpc_cidr]
}

run "reject_private_172_lower_neighbor" {
  command = plan

  variables {
    vpc_cidr = "172.15.0.0/16"
  }

  expect_failures = [var.vpc_cidr]
}

run "reject_private_172_upper_neighbor" {
  command = plan

  variables {
    vpc_cidr = "172.32.0.0/16"
  }

  expect_failures = [var.vpc_cidr]
}

run "reject_private_192_neighbor" {
  command = plan

  variables {
    vpc_cidr = "192.169.0.0/16"
  }

  expect_failures = [var.vpc_cidr]
}

run "reject_too_broad" {
  command = plan

  variables {
    vpc_cidr = "10.0.0.0/15"
  }

  expect_failures = [var.vpc_cidr]
}

run "reject_too_small" {
  command = plan

  variables {
    vpc_cidr = "10.20.0.0/25"
  }

  expect_failures = [var.vpc_cidr]
}

run "reject_whitespace" {
  command = plan

  variables {
    vpc_cidr = " 10.20.0.0/16"
  }

  expect_failures = [var.vpc_cidr]
}

run "reject_leading_zero_octet" {
  command = plan

  variables {
    vpc_cidr = "10.020.0.0/16"
  }

  expect_failures = [var.vpc_cidr]
}

run "reject_leading_zero_prefix" {
  command = plan

  variables {
    vpc_cidr = "10.20.0.0/016"
  }

  expect_failures = [var.vpc_cidr]
}

run "reject_empty" {
  command = plan

  variables {
    vpc_cidr = ""
  }

  expect_failures = [var.vpc_cidr]
}

run "reject_null" {
  command = plan

  variables {
    vpc_cidr = null
  }

  expect_failures = [var.vpc_cidr]
}
