locals {
  # Append a resource role, for example "${local.name_prefix}-vpc".
  name_prefix = "${var.project_name}-${var.environment}"

  # Mandatory identity tags take precedence over caller-supplied values.
  resource_tags = merge(var.common_tags, {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "terraform"
    Owner       = trimspace(var.common_tags["Owner"])
  })
}
