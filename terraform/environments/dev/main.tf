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

module "eks" {
  source = "../../modules/eks"
  count  = var.enable_eks ? 1 : 0

  name_prefix              = local.name_prefix
  cluster_version          = var.eks_cluster_version
  vpc_id                   = module.network.vpc_id
  private_subnet_ids       = module.network.private_subnet_ids
  cluster_role_arn         = module.ecr.eks_cluster_role_arn
  node_role_arn            = module.ecr.eks_node_role_arn
  admin_role_arns          = var.eks_admin_role_arns
  admin_access_cidrs       = var.eks_admin_access_cidrs
  node_ami_release_version = var.eks_node_ami_release_version
  secrets_kms_key_arn      = var.eks_secrets_kms_key_arn
  tags                     = local.resource_tags
}
