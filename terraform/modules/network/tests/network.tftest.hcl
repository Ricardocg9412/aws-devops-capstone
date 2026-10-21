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

run "lab_topology" {
  command = apply

  assert {
    condition     = aws_vpc.this.enable_dns_support && aws_vpc.this.enable_dns_hostnames
    error_message = "VPC DNS support and hostnames must be enabled."
  }
  assert {
    condition = output.public_subnet_cidrs == tomap({
      us-east-1a = "10.20.1.0/24"
      us-east-1b = "10.20.2.0/24"
      }) && output.private_subnet_cidrs == tomap({
      us-east-1a = "10.20.11.0/24"
      us-east-1b = "10.20.12.0/24"
    })
    error_message = "Subnet allocation must exactly match the assignment topology."
  }
  assert {
    condition = alltrue([for az in var.availability_zones :
      aws_route_table_association.public[az].subnet_id == aws_subnet.public[az].id &&
      aws_route_table_association.public[az].route_table_id == aws_route_table.public.id &&
      aws_route_table_association.private[az].subnet_id == aws_subnet.private[az].id &&
      aws_route_table_association.private[az].route_table_id == aws_route_table.private[az].id
    ]) && aws_route.public_internet.gateway_id == aws_internet_gateway.this.id && aws_route.public_internet.destination_cidr_block == "0.0.0.0/0"
    error_message = "Subnets must have the correct public/private route table associations and public IGW route."
  }
  assert {
    condition     = length(aws_nat_gateway.this) == 0 && length(aws_eip.nat) == 0 && length(aws_route.private_nat) == 0
    error_message = "The lab must not create NAT Gateways, EIPs, or private internet routes."
  }
  assert {
    condition = alltrue([for az in var.availability_zones :
      aws_subnet.public[az].tags["kubernetes.io/role/elb"] == "1" &&
      aws_subnet.private[az].tags["kubernetes.io/role/internal-elb"] == "1" &&
      !aws_subnet.public[az].map_public_ip_on_launch && !aws_subnet.private[az].map_public_ip_on_launch
    ])
    error_message = "Subnet discovery tags must be present and automatic public IPs disabled."
  }
  assert {
    condition = length(aws_security_group.workload.ingress) == 0 && length(aws_default_security_group.this.ingress) == 0 && length(aws_default_security_group.this.egress) == 0 && alltrue([
      for rule in aws_security_group.workload.egress : rule.from_port == 443 && rule.to_port == 443 && rule.protocol == "tcp"
    ]) && length(aws_security_group.workload.egress) == 1
    error_message = "No ingress is permitted; workload egress must be HTTPS only and default SG must deny all."
  }
  assert {
    condition = aws_vpc.this.tags.Name == "inventory-api-dev-vpc" && aws_vpc.this.tags.Project == "inventory-api" && alltrue([
      for az in var.availability_zones : aws_subnet.private[az].tags.Environment == "dev" && aws_route_table.private[az].tags.Owner == "platform-team"
    ])
    error_message = "Names and mandatory tags must be applied."
  }
}

run "nat_per_az" {
  command = apply
  variables {
    enable_nat_gateway = true
  }
  assert {
    condition = length(aws_nat_gateway.this) == 2 && length(aws_eip.nat) == 2 && length(aws_route.private_nat) == 2 && alltrue([
      for az in var.availability_zones :
      aws_nat_gateway.this[az].subnet_id == aws_subnet.public[az].id &&
      aws_nat_gateway.this[az].allocation_id == aws_eip.nat[az].id &&
      aws_route.private_nat[az].route_table_id == aws_route_table.private[az].id &&
      aws_route.private_nat[az].nat_gateway_id == aws_nat_gateway.this[az].id &&
      aws_route.private_nat[az].destination_cidr_block == "0.0.0.0/0"
    ])
    error_message = "Each AZ must use its own public NAT Gateway and private default route."
  }
}

run "small_parent_network" {
  command = plan
  variables {
    vpc_cidr = "192.168.1.0/24"
  }
  assert {
    condition     = output.public_subnet_cidrs["us-east-1a"] == "192.168.1.16/28" && output.private_subnet_cidrs["us-east-1b"] == "192.168.1.192/28"
    error_message = "Smaller parents must still produce valid contained, distinct subnet ranges."
  }
}
