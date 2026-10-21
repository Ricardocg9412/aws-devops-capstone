module "network" {
  source = "../../modules/network"

  name_prefix        = local.name_prefix
  vpc_cidr           = var.vpc_cidr
  availability_zones = var.availability_zones
  enable_nat_gateway = var.enable_nat_gateway
  tags               = local.resource_tags
}

module "ecr" {
  source = "../../modules/ecr"

  name_prefix               = local.name_prefix
  tags                      = local.resource_tags
  github_repository         = var.github_repository
  github_branch             = var.github_branch
  github_environment        = var.github_environment
  github_subject_repository = var.github_subject_repository
  github_oidc_provider_arn  = var.github_oidc_provider_arn
}
