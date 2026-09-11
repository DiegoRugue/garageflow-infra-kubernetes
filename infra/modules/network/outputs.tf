output "vpc_id" {
  description = "ID of the environment VPC."
  value       = aws_vpc.this.id
}

output "vpc_cidr" {
  description = "CIDR assigned to the environment VPC."
  value       = aws_vpc.this.cidr_block
}

output "public_subnet_ids" {
  description = "Public worker subnet IDs ordered by availability zone."
  value       = aws_subnet.public[*].id
}

output "private_application_subnet_ids" {
  description = "Private application subnet IDs ordered by availability zone."
  value       = aws_subnet.private_application[*].id
}

output "database_subnet_ids" {
  description = "Dedicated private database subnet IDs ordered by availability zone."
  value       = aws_subnet.database[*].id
}

output "private_application_route_table_ids" {
  description = "Explicit local-only route tables for application subnets."
  value       = aws_route_table.private_application[*].id
}

output "database_route_table_ids" {
  description = "Explicit local-only route tables for database subnets."
  value       = aws_route_table.database[*].id
}

output "secrets_manager_endpoint_id" {
  description = "Interface endpoint used by later VPC functions to retrieve secrets privately."
  value       = aws_vpc_endpoint.secrets_manager.id
}

output "secrets_manager_private_dns_enabled" {
  description = "Whether the Secrets Manager endpoint resolves through private DNS."
  value       = aws_vpc_endpoint.secrets_manager.private_dns_enabled
}
