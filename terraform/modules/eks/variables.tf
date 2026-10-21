variable "name_prefix" {
  description = "Project/environment naming prefix."
  type        = string
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,44}$", var.name_prefix))
    error_message = "name_prefix must contain 1-45 lowercase letters, digits, or hyphens, starting with a letter."
  }
}
variable "cluster_version" {
  description = "Reviewed EKS minor version; defaults to 1.35, verified supported on 2026-10-21."
  type        = string
  default     = "1.35"
  validation {
    condition     = contains(["1.34", "1.35"], var.cluster_version)
    error_message = "Choose a reviewed supported version: 1.34 or 1.35. Update this allowlist as support changes."
  }
}
variable "vpc_id" {
  description = "VPC containing the private cluster/node subnets."
  type        = string
}
variable "private_subnet_ids" {
  description = "Exactly two private subnet IDs keyed by AZ; inspected for VPC and public-IP settings."
  type        = map(string)
  validation {
    condition     = try(length(var.private_subnet_ids) == 2 && length(distinct(values(var.private_subnet_ids))) == 2, false)
    error_message = "Supply exactly two distinct private subnet IDs keyed by availability zone."
  }
}
variable "cluster_role_arn" {
  description = "Existing EKS control-plane role ARN; caller must order its policy attachments."
  type        = string
}
variable "node_role_arn" {
  description = "Existing managed-node role ARN, with worker-node and ECR pull policies attached."
  type        = string
  validation {
    condition     = var.node_role_arn != var.cluster_role_arn
    error_message = "Cluster and node roles must be separate identities."
  }
}
variable "admin_role_arns" {
  description = "Explicit IAM role ARNs receiving cluster-admin access entries; no implicit creator access."
  type        = set(string)
  validation {
    condition = try(length(var.admin_role_arns) > 0 && alltrue([
      for arn in var.admin_role_arns : can(regex("^arn:aws(-[a-z]+)*:iam::[0-9]{12}:role/.+$", arn)) && arn != var.cluster_role_arn && arn != var.node_role_arn
    ]), false)
    error_message = "Supply at least one permanent IAM admin role ARN, distinct from the cluster and node roles. STS session/user ARNs are not accepted."
  }
}
variable "admin_access_cidrs" {
  description = "IPv4 source networks allowed HTTPS to the private API SG; routing/VPN/SSM access must exist separately."
  type        = set(string)
  default     = []
  validation {
    condition = alltrue([for cidr in var.admin_access_cidrs : try(
      can(cidrnetmask(cidr)) && tonumber(split("/", cidr)[1]) >= 16 &&
      cidr == "${cidrhost(cidr, 0)}/${tonumber(split("/", cidr)[1])}", false
    )])
    error_message = "Admin source CIDRs must be canonical IPv4 networks /16 or narrower, never a world-open range."
  }
}
variable "node_scaling" {
  description = "Managed-node scaling limits; Terraform owns desired_size until autoscaling is configured."
  type        = object({ min = number, desired = number, max = number })
  default     = { min = 1, desired = 2, max = 3 }
  validation {
    condition = try(var.node_scaling.min >= 1 && var.node_scaling.min <= var.node_scaling.desired && var.node_scaling.desired <= var.node_scaling.max && alltrue([
      for size in [var.node_scaling.min, var.node_scaling.desired, var.node_scaling.max] : floor(size) == size
    ]), false)
    error_message = "Scaling must use whole numbers with 1 <= min <= desired <= max."
  }
}
variable "node_ami_release_version" {
  description = "Optional EKS AL2023 release pin matching cluster_version; null lets EKS choose at creation. Not an AMI ID."
  type        = string
  default     = null
  validation {
    condition     = var.node_ami_release_version == null ? true : try(startswith(var.node_ami_release_version, "${var.cluster_version}.") && !startswith(var.node_ami_release_version, "ami-"), false)
    error_message = "Provide an EKS AL2023 release version matching cluster_version, not an AMI ID."
  }
}
variable "secrets_kms_key_arn" {
  description = "Optional same-region symmetric customer-managed KMS key ARN; null uses EKS default AWS-owned envelope encryption."
  type        = string
  default     = null
  validation {
    condition     = var.secrets_kms_key_arn == null ? true : can(regex("^arn:aws(-[a-z]+)*:kms:[a-z0-9-]+:[0-9]{12}:key/.+$", var.secrets_kms_key_arn))
    error_message = "Provide a KMS key ARN or null; aliases and credentials are not accepted."
  }
}
variable "tags" {
  description = "Mandatory Project, Environment, ManagedBy, and Owner tags plus optional tags."
  type        = map(string)
  validation {
    condition     = alltrue([for key in ["Project", "Environment", "ManagedBy", "Owner"] : try(trimspace(var.tags[key]) != "", false)])
    error_message = "tags must include non-empty Project, Environment, ManagedBy, and Owner."
  }
}
