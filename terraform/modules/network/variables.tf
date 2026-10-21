variable "name_prefix" {
  description = "Project/environment prefix for resource names."
  type        = string
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,44}$", var.name_prefix))
    error_message = "name_prefix must start with a lowercase letter and contain up to 45 lowercase letters, digits, or hyphens."
  }
}

variable "vpc_cidr" {
  description = "Canonical private IPv4 network, /16 through /24. Subnets use eight additional bits, capped at /28."
  type        = string
  validation {
    condition = try(
      can(cidrnetmask(var.vpc_cidr)) &&
      tonumber(split("/", var.vpc_cidr)[1]) >= 16 &&
      tonumber(split("/", var.vpc_cidr)[1]) <= 24 &&
      var.vpc_cidr == "${cidrhost(var.vpc_cidr, 0)}/${tonumber(split("/", var.vpc_cidr)[1])}" &&
      can(regex("^(10\\.|172\\.(1[6-9]|2[0-9]|3[01])\\.|192\\.168\\.)", var.vpc_cidr)), false
    )
    error_message = "vpc_cidr must be a canonical RFC 1918 IPv4 network with a /16 through /24 prefix."
  }
}

variable "availability_zones" {
  description = "Exactly two distinct AZ names, ordered A then B."
  type        = list(string)
  validation {
    condition = try(length(var.availability_zones) == 2 && length(distinct(var.availability_zones)) == 2 && alltrue([
      for az in var.availability_zones : can(regex("^[a-z]{2}(-[a-z]+)+-[0-9]+[a-z]$", az))
    ]), false)
    error_message = "availability_zones must contain exactly two distinct standard AWS AZ names."
  }
}

variable "enable_nat_gateway" {
  description = "Create one NAT Gateway per AZ and private default routes. Disabled for the lab."
  type        = bool
  default     = false
  nullable    = false
}

variable "tags" {
  description = "Mandatory Project, Environment, ManagedBy, Owner tags plus optional tags."
  type        = map(string)
  validation {
    condition = alltrue([
      for tag in ["Project", "Environment", "ManagedBy", "Owner"] : try(trimspace(var.tags[tag]) != "", false)
    ])
    error_message = "tags must include non-empty Project, Environment, ManagedBy, and Owner."
  }
}
