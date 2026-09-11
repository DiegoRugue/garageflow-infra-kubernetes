resource "aws_eks_cluster" "this" {
  name     = var.cluster_name
  role_arn = var.cluster_role_arn
  version  = var.kubernetes_version

  vpc_config {
    subnet_ids              = var.public_subnet_ids
    endpoint_public_access  = true
    endpoint_private_access = true
    public_access_cidrs     = var.public_access_cidrs
  }

  access_config {
    authentication_mode                         = "API_AND_CONFIG_MAP"
    bootstrap_cluster_creator_admin_permissions = true
  }

  upgrade_policy { support_type = "STANDARD" }
  tags = var.tags
}

resource "aws_eks_node_group" "this" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "${var.cluster_name}-workers"
  node_role_arn   = var.node_role_arn
  subnet_ids      = var.public_subnet_ids
  capacity_type   = "ON_DEMAND"
  instance_types  = ["t3.small"]
  scaling_config {
    min_size     = 2
    desired_size = 2
    max_size     = 2
  }
  update_config { max_unavailable = 1 }
  tags = var.tags
}
