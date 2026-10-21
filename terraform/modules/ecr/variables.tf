variable "name_prefix" {
  description = "Project/environment naming prefix, for example inventory-api-dev."
  type        = string
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,44}$", var.name_prefix))
    error_message = "name_prefix must be 1-45 lowercase letters, digits, or hyphens, starting with a letter."
  }
}
variable "tags" {
  description = "Mandatory Project, Environment, ManagedBy, and Owner tags plus optional tags."
  type        = map(string)
  validation {
    condition     = alltrue([for key in ["Project", "Environment", "ManagedBy", "Owner"] : try(trimspace(var.tags[key]) != "", false)])
    error_message = "tags must contain non-empty Project, Environment, ManagedBy, and Owner."
  }
}
variable "github_repository" {
  description = "Exact case-sensitive GitHub OWNER/REPOSITORY trusted to publish."
  type        = string
  validation {
    condition     = can(regex("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", var.github_repository))
    error_message = "github_repository must be an exact OWNER/REPOSITORY without wildcards."
  }
}
variable "github_branch" {
  description = "Exact publishing branch when github_environment is null."
  type        = string
  default     = "main"
  validation {
    condition     = try(length(trimspace(var.github_branch)) > 0 && !can(regex("[\\s*?:]", var.github_branch)), false)
    error_message = "github_branch must be nonempty with no whitespace, wildcards, or colons."
  }
}
variable "github_environment" {
  description = "Optional exact GitHub environment instead of branch trust; protect allowed branches in GitHub."
  type        = string
  default     = null
  validation {
    condition     = var.github_environment == null ? true : try(length(trimspace(var.github_environment)) > 0 && !can(regex("[*?%:]", var.github_environment)), false)
    error_message = "github_environment must be null or a nonempty exact name without wildcards, colons, or percent encoding."
  }
}
variable "github_subject_repository" {
  description = "Optional OIDC repository identity with immutable IDs (OWNER@ID/REPO@ID); must refer to github_repository. Null uses legacy OWNER/REPO."
  type        = string
  default     = null
  validation {
    condition = var.github_subject_repository == null ? true : try(
      can(regex("^[A-Za-z0-9_.-]+@[0-9]+/[A-Za-z0-9_.-]+@[0-9]+$", var.github_subject_repository)) &&
      replace(var.github_subject_repository, "/@[0-9]+/", "") == var.github_repository, false
    )
    error_message = "github_subject_repository must be null or OWNER@ID/REPO@ID matching github_repository."
  }
}
variable "github_oidc_provider_arn" {
  description = "Existing account GitHub OIDC provider ARN; null creates one. Reuse across environments."
  type        = string
  default     = null
  validation {
    condition     = var.github_oidc_provider_arn == null ? true : can(regex("^arn:aws(-[a-z]+)*:iam::[0-9]{12}:oidc-provider/token\\.actions\\.githubusercontent\\.com$", var.github_oidc_provider_arn))
    error_message = "Provide the ARN of the GitHub Actions OIDC provider or null."
  }
}
variable "untagged_expiration_days" {
  description = "Expire untagged images after this many days."
  type        = number
  default     = 7
  validation {
    condition     = try(var.untagged_expiration_days >= 1 && floor(var.untagged_expiration_days) == var.untagged_expiration_days, false)
    error_message = "untagged_expiration_days must be a positive integer."
  }
}
variable "retained_sha_images" {
  description = "Number of images carrying sha-* tags to retain; images with only other tags are excluded."
  type        = number
  default     = 30
  validation {
    condition     = try(var.retained_sha_images >= 1 && floor(var.retained_sha_images) == var.retained_sha_images, false)
    error_message = "retained_sha_images must be a positive integer."
  }
}
