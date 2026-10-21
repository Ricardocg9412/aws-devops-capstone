variable "project_name" {
  type        = string
  default     = "inventory-api"
  description = "Project name used in resource names and the Project tag."

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,39}$", var.project_name))
    error_message = "project_name must contain 1-40 lowercase letters, digits, or hyphens, starting with a letter."
  }
}

variable "environment" {
  type        = string
  default     = "dev"
  description = "Deployment environment: dev or prod."

  validation {
    condition     = contains(["dev", "prod"], var.environment)
    error_message = "environment must be either dev or prod."
  }
}

variable "aws_region" {
  description = "AWS region where resources will be deployed"
  type        = string
  default     = "us-east-1"
}

variable "vpc_cidr" {
  description = "Canonical RFC 1918 IPv4 VPC network with a /16 through /24 prefix."
  type        = string
  default     = "10.20.0.0/16"

  validation {
    # try catches parsing errors; logical operators alone are not error guards.
    condition = try(
      can(cidrnetmask(var.vpc_cidr)) &&
      tonumber(split("/", var.vpc_cidr)[1]) >= 16 &&
      tonumber(split("/", var.vpc_cidr)[1]) <= 24 &&
      var.vpc_cidr == "${cidrhost(var.vpc_cidr, 0)}/${tonumber(split("/", var.vpc_cidr)[1])}" &&
      can(regex("^(10\\.|172\\.(1[6-9]|2[0-9]|3[01])\\.|192\\.168\\.)", var.vpc_cidr)),
      false
    )
    error_message = "vpc_cidr must be a canonical private IPv4 network within 10.0.0.0/8, 172.16.0.0/12, or 192.168.0.0/16, with a /16 through /24 prefix (for example 10.20.0.0/16). Host bits, IPv6, and public ranges are not allowed."
  }
}

variable "availability_zones" {
  description = "Exactly two distinct availability zones in aws_region, ordered A then B."
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b"]

  validation {
    condition = try(length(var.availability_zones) == 2 && length(distinct(var.availability_zones)) == 2 && alltrue([
      for az in var.availability_zones : can(regex("^[a-z]{2}(-[a-z]+)+-[0-9]+[a-z]$", az)) && startswith(az, var.aws_region) && length(az) == length(var.aws_region) + 1
    ]), false)
    error_message = "Provide exactly two distinct standard AZ names belonging to aws_region."
  }
}

variable "enable_nat_gateway" {
  description = "Create one NAT Gateway per AZ. Disabled by default for the local lab."
  type        = bool
  default     = false
  nullable    = false
}

variable "common_tags" {
  description = "Required non-empty Project, Environment, ManagedBy, and Owner tags plus optional tags. Project, Environment, and ManagedBy are normalized by the root module."
  type        = map(string)

  default = {
    Project     = "inventory-api"
    Environment = "dev"
    ManagedBy   = "terraform"
    Owner       = "platform-team"
  }

  validation {
    condition = alltrue([
      for tag in ["Project", "Environment", "ManagedBy", "Owner"] :
      try(trimspace(var.common_tags[tag]) != "", false)
    ])
    error_message = "common_tags must contain non-empty Project, Environment, ManagedBy, and Owner values."
  }
}

variable "github_repository" {
  description = "Exact GitHub OWNER/REPOSITORY allowed to publish images."
  type        = string
  default     = "Ricardocg9412/aws-devops-capstone"
}
variable "github_branch" {
  description = "Exact publishing branch when no GitHub environment is configured."
  type        = string
  default     = "main"
}
variable "github_environment" {
  description = "Optional protected GitHub environment instead of branch-based trust."
  type        = string
  default     = null
}
variable "github_subject_repository" {
  description = "Optional immutable OIDC subject repository identity OWNER@ID/REPO@ID."
  type        = string
  default     = null
}
variable "github_oidc_provider_arn" {
  description = "Existing GitHub OIDC provider ARN; null creates one."
  type        = string
  default     = null
}
