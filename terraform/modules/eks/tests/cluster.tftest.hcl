mock_provider "aws" {
  mock_resource "aws_launch_template" {
    defaults = {
      id             = "lt-0123456789abcdef0"
      latest_version = 1
    }
  }
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::123456789012:role/vpc-cni" }
  }
  mock_data "aws_partition" {
    defaults = {
      partition  = "aws"
      dns_suffix = "amazonaws.com"
    }
  }
  mock_data "aws_subnet" {
    defaults = {
      map_public_ip_on_launch = false
      vpc_id                  = "vpc-12345678"
    }
  }
  mock_resource "aws_eks_cluster" {
    defaults = {
      identity              = [{ oidc = [{ issuer = "https://oidc.eks.us-east-1.amazonaws.com/id/TEST" }] }]
      certificate_authority = [{ data = "dGVzdA==" }]
      endpoint              = "https://example.eks.amazonaws.com"
    }
  }
}
variables {
  name_prefix        = "inventory-api-dev"
  vpc_id             = "vpc-12345678"
  private_subnet_ids = { us-east-1a = "subnet-12345678", us-east-1b = "subnet-87654321" }
  cluster_role_arn   = "arn:aws:iam::123456789012:role/eks-cluster"
  node_role_arn      = "arn:aws:iam::123456789012:role/eks-node"
  admin_role_arns    = ["arn:aws:iam::123456789012:role/platform-admin"]
  admin_access_cidrs = ["10.30.0.0/24"]
  tags               = { Project = "inventory-api", Environment = "dev", ManagedBy = "terraform", Owner = "platform-team" }
}

run "private_managed_cluster" {
  command = apply
  assert {
    condition     = aws_eks_cluster.this.name == "inventory-api-dev-eks" && aws_eks_cluster.this.version == "1.35" && aws_eks_cluster.this.vpc_config[0].endpoint_private_access && !aws_eks_cluster.this.vpc_config[0].endpoint_public_access
    error_message = "Cluster naming, reviewed version, and private-only endpoint must be configured."
  }
  assert {
    condition     = toset(aws_eks_node_group.this.subnet_ids) == toset(values(var.private_subnet_ids)) && aws_eks_node_group.this.scaling_config[0].desired_size == 2 && aws_eks_node_group.this.scaling_config[0].min_size == 1 && aws_eks_node_group.this.scaling_config[0].max_size == 3 && aws_eks_node_group.this.ami_type == "AL2023_x86_64_STANDARD" && aws_eks_node_group.this.version == aws_eks_cluster.this.version && toset(aws_eks_node_group.this.instance_types) == toset(["t3.medium"])
    error_message = "Managed workers must use private subnets, AL2023 x86-64, compatible instance type/version, and 1/2/3 scaling."
  }
  assert {
    condition     = aws_eks_cluster.this.access_config[0].authentication_mode == "API" && !aws_eks_cluster.this.access_config[0].bootstrap_cluster_creator_admin_permissions && length(aws_eks_access_entry.admin) == 1 && aws_eks_access_entry.admin["arn:aws:iam::123456789012:role/platform-admin"].type == "STANDARD" && aws_eks_access_policy_association.admin["arn:aws:iam::123456789012:role/platform-admin"].access_scope[0].type == "cluster"
    error_message = "Administrative access must be explicit and use API access entries."
  }
  assert {
    condition     = toset(aws_eks_cluster.this.enabled_cluster_log_types) == toset(["api", "audit", "authenticator", "controllerManager", "scheduler"]) && aws_cloudwatch_log_group.control_plane.retention_in_days == 30 && length(aws_eks_cluster.this.encryption_config) == 0
    error_message = "All control-plane log types must be enabled; default encryption must not require a customer KMS key."
  }
  assert {
    condition     = alltrue([for nic in aws_launch_template.workers.network_interfaces : !nic.associate_public_ip_address]) && aws_launch_template.workers.metadata_options[0].http_tokens == "required" && alltrue([for mapping in aws_launch_template.workers.block_device_mappings : mapping.ebs[0].encrypted])
    error_message = "Worker launch settings must disable public IPs, require IMDSv2, and encrypt root volumes."
  }
  assert {
    condition     = alltrue([for rule in aws_vpc_security_group_ingress_rule.admin_api : rule.cidr_ipv4 == "10.30.0.0/24" && rule.from_port == 443 && rule.to_port == 443]) && aws_eks_addon.vpc_cni.service_account_role_arn == aws_iam_role.vpc_cni.arn && jsondecode(aws_iam_role.vpc_cni.assume_role_policy).Statement[0].Condition.StringEquals["oidc.eks.us-east-1.amazonaws.com/id/TEST:sub"] == "system:serviceaccount:kube-system:aws-node"
    error_message = "Admin ingress must be scoped and CNI must use its own exact service-account identity."
  }
}
run "custom_kms_and_ami_release" {
  command = plan
  variables {
    secrets_kms_key_arn      = "arn:aws:kms:us-east-1:123456789012:key/11111111-2222-3333-4444-555555555555"
    node_ami_release_version = "1.35.0-20261001"
  }
  assert {
    condition     = aws_eks_cluster.this.encryption_config[0].provider[0].key_arn == var.secrets_kms_key_arn && aws_eks_node_group.this.release_version == var.node_ami_release_version
    error_message = "Optional customer KMS key and version-compatible AMI release pin must be forwarded."
  }
}
