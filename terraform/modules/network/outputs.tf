output "vpc_id" {
  description = "VPC ID for EKS and other consumers."
  value       = aws_vpc.this.id
}

output "vpc_cidr" {
  description = "Allocated VPC CIDR."
  value       = aws_vpc.this.cidr_block
}

output "public_subnet_ids" {
  description = "Public subnet IDs keyed by AZ."
  value       = tomap({ for az, subnet in aws_subnet.public : az => subnet.id })
}

output "private_subnet_ids" {
  description = "Private subnet IDs keyed by AZ for EKS nodes."
  value       = tomap({ for az, subnet in aws_subnet.private : az => subnet.id })
}

output "public_subnet_cidrs" {
  description = "Public subnet CIDRs keyed by AZ."
  value       = tomap({ for az, subnet in aws_subnet.public : az => subnet.cidr_block })
}

output "private_subnet_cidrs" {
  description = "Private subnet CIDRs keyed by AZ."
  value       = tomap({ for az, subnet in aws_subnet.private : az => subnet.cidr_block })
}

output "public_route_table_id" {
  description = "Shared public route table ID."
  value       = aws_route_table.public.id
}

output "private_route_table_ids" {
  description = "Private route table IDs keyed by AZ, for future endpoint associations."
  value       = tomap({ for az, table in aws_route_table.private : az => table.id })
}

output "nat_gateway_ids" {
  description = "NAT Gateway IDs keyed by AZ; empty when disabled."
  value       = tomap({ for az, gateway in aws_nat_gateway.this : az => gateway.id })
}

output "workload_security_group_id" {
  description = "Baseline SG ID; EKS-specific communication rules must be added by the EKS module."
  value       = aws_security_group.workload.id
}
