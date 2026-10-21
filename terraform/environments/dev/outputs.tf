output "vpc_id" {
  description = "Network VPC ID."
  value       = module.network.vpc_id
}

output "vpc_cidr" {
  description = "Allocated VPC CIDR."
  value       = module.network.vpc_cidr
}

output "public_subnet_ids" {
  description = "Public subnet IDs keyed by AZ."
  value       = module.network.public_subnet_ids
}

output "private_subnet_ids" {
  description = "Private subnet IDs keyed by AZ."
  value       = module.network.private_subnet_ids
}

output "public_subnet_cidrs" {
  description = "Public subnet CIDRs keyed by AZ."
  value       = module.network.public_subnet_cidrs
}

output "private_subnet_cidrs" {
  description = "Private subnet CIDRs keyed by AZ."
  value       = module.network.private_subnet_cidrs
}

output "public_route_table_id" {
  description = "Public route table ID."
  value       = module.network.public_route_table_id
}

output "private_route_table_ids" {
  description = "Private route table IDs keyed by AZ."
  value       = module.network.private_route_table_ids
}

output "nat_gateway_ids" {
  description = "NAT Gateway IDs keyed by AZ; empty when disabled."
  value       = module.network.nat_gateway_ids
}

output "workload_security_group_id" {
  description = "Baseline workload SG ID."
  value       = module.network.workload_security_group_id
}

