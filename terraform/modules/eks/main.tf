resource "aws_cloudwatch_log_group" "control_plane" {
  name              = "/aws/eks/${local.cluster_name}/cluster"
  retention_in_days = 30
  tags              = var.tags
}

resource "aws_eks_cluster" "this" {
  name                      = local.cluster_name
  role_arn                  = var.cluster_role_arn
  version                   = var.cluster_version
  enabled_cluster_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  access_config {
    authentication_mode                         = "API"
    bootstrap_cluster_creator_admin_permissions = false
  }
  vpc_config {
    subnet_ids              = values(var.private_subnet_ids)
    endpoint_private_access = true
    endpoint_public_access  = false
  }
  upgrade_policy {
    support_type = "STANDARD"
  }
  dynamic "encryption_config" {
    for_each = var.secrets_kms_key_arn == null ? [] : [var.secrets_kms_key_arn]
    content {
      resources = ["secrets"]
      provider {
        key_arn = encryption_config.value
      }
    }
  }
  depends_on = [aws_cloudwatch_log_group.control_plane]
  tags       = var.tags
}

resource "aws_eks_access_entry" "admin" {
  for_each      = var.admin_role_arns
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = each.value
  type          = "STANDARD"
  tags          = var.tags
}

resource "aws_eks_access_policy_association" "admin" {
  for_each      = var.admin_role_arns
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = aws_eks_access_entry.admin[each.key].principal_arn
  policy_arn    = "arn:${data.aws_partition.current.partition}:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
  access_scope {
    type = "cluster"
  }
}

resource "aws_vpc_security_group_ingress_rule" "admin_api" {
  for_each          = var.admin_access_cidrs
  security_group_id = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
  description       = "HTTPS from approved private administrative access path."
  cidr_ipv4         = each.value
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  tags              = var.tags
}

# CNI permissions belong to aws-node, not every worker node.
resource "aws_iam_openid_connect_provider" "cluster" {
  url            = aws_eks_cluster.this.identity[0].oidc[0].issuer
  client_id_list = ["sts.amazonaws.com"]
  tags           = var.tags
}
resource "aws_iam_role" "vpc_cni" {
  name = "${var.name_prefix}-vpc-cni"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRoleWithWebIdentity"
      Principal = { Federated = aws_iam_openid_connect_provider.cluster.arn }
      Condition = { StringEquals = {
        "${local.oidc_issuer}:aud" = "sts.amazonaws.com"
        "${local.oidc_issuer}:sub" = "system:serviceaccount:kube-system:aws-node"
      } }
    }]
  })
  tags = var.tags
}
resource "aws_iam_role_policy_attachment" "vpc_cni" {
  role       = aws_iam_role.vpc_cni.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKS_CNI_Policy"
}
resource "aws_eks_addon" "vpc_cni" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "vpc-cni"
  service_account_role_arn    = aws_iam_role.vpc_cni.arn
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "PRESERVE"
  depends_on                  = [aws_iam_role_policy_attachment.vpc_cni]
  tags                        = var.tags
}

resource "aws_launch_template" "workers" {
  name_prefix = "${var.name_prefix}-workers-"
  # EKS selects the version-compatible AL2023 AMI; do not set image_id here.
  network_interfaces {
    device_index                = 0
    associate_public_ip_address = false
    delete_on_termination       = true
  }
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }
  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      encrypted             = true
      volume_type           = "gp3"
      volume_size           = 20
      delete_on_termination = true
    }
  }
  tag_specifications {
    resource_type = "instance"
    tags          = merge(var.tags, { Name = "${var.name_prefix}-worker" })
  }
  tag_specifications {
    resource_type = "volume"
    tags          = var.tags
  }
  tags = var.tags
}

resource "aws_eks_node_group" "this" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "${var.name_prefix}-workers"
  node_role_arn   = var.node_role_arn
  subnet_ids      = values(var.private_subnet_ids)
  version         = var.cluster_version
  ami_type        = "AL2023_x86_64_STANDARD"
  release_version = var.node_ami_release_version
  instance_types  = ["t3.medium"]
  capacity_type   = "ON_DEMAND"
  scaling_config {
    desired_size = var.node_scaling.desired
    min_size     = var.node_scaling.min
    max_size     = var.node_scaling.max
  }
  update_config {
    max_unavailable = 1
  }
  launch_template {
    id      = aws_launch_template.workers.id
    version = tostring(aws_launch_template.workers.latest_version)
  }
  lifecycle {
    precondition {
      condition     = alltrue([for subnet in data.aws_subnet.worker : !subnet.map_public_ip_on_launch && subnet.vpc_id == var.vpc_id])
      error_message = "Worker subnets must belong to the cluster VPC and disable map_public_ip_on_launch. Public-IP-enabled subnets are forbidden."
    }
  }
  depends_on = [aws_eks_addon.vpc_cni]
  tags       = var.tags
}
