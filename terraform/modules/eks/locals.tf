data "aws_partition" "current" {}

locals {
  cluster_name = "${var.name_prefix}-eks"
  oidc_issuer  = replace(aws_eks_cluster.this.identity[0].oidc[0].issuer, "https://", "")
}

data "aws_subnet" "worker" {
  for_each = var.private_subnet_ids
  id       = each.value
}
