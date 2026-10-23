# One node, in the private subnets, with no public address and IMDSv2 only.

resource "aws_iam_role" "node" {
  name                 = "${var.cluster_name}-node"
  permissions_boundary = var.iam_permissions_boundary
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "node" {
  for_each = toset([
    "AmazonEKSWorkerNodePolicy",
    "AmazonEKS_CNI_Policy",
    "AmazonEC2ContainerRegistryPullOnly",
  ])
  role       = aws_iam_role.node.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/${each.value}"
}

resource "aws_launch_template" "node" {
  name_prefix = "${var.cluster_name}-node-"

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  tag_specifications {
    resource_type = "instance"
    tags          = { Name = "${var.cluster_name}-node" }
  }
}

resource "aws_eks_node_group" "this" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "${var.cluster_name}-node"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = aws_subnet.private[*].id
  ami_type        = "AL2023_x86_64_STANDARD"
  instance_types  = [var.node_instance_type]
  capacity_type   = "ON_DEMAND"

  scaling_config {
    desired_size = 1
    min_size     = 1
    max_size     = 1
  }

  launch_template {
    id      = aws_launch_template.node.id
    version = aws_launch_template.node.latest_version
  }

  depends_on = [
    aws_eks_addon.before_nodes,
    aws_iam_role_policy_attachment.node,
    aws_vpc_endpoint.interface,
    aws_vpc_endpoint.s3,
    aws_route53_resolver_firewall_rule.allow_aws,
  ]
}

# The GPU node (ADR 19), when the run asks for one: EKS's AL2023 image with
# NVIDIA's driver and container toolkit, one L4, the same IMDSv2 rule, and a
# taint, so only what asks for a GPU lands on it. A larger root volume: the
# CUDA build of llama-server is 2.5 GB compressed. The NVIDIA device plugin
# that offers the GPU to the scheduler arrives in the bundle like everything
# else (manifests/gpu/device-plugin.yaml).
resource "aws_launch_template" "gpu" {
  count       = var.gpu ? 1 : 0
  name_prefix = "${var.cluster_name}-gpu-"

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = 60
      volume_type           = "gp3"
      delete_on_termination = true
      encrypted             = true
    }
  }

  tag_specifications {
    resource_type = "instance"
    tags          = { Name = "${var.cluster_name}-gpu" }
  }
}

resource "aws_eks_node_group" "gpu" {
  count           = var.gpu ? 1 : 0
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "${var.cluster_name}-gpu"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = aws_subnet.private[*].id
  ami_type        = "AL2023_x86_64_NVIDIA"
  instance_types  = [var.gpu_instance_type]
  capacity_type   = "ON_DEMAND"

  labels = {
    "boundary.heyvaldemar.com/accelerator" = "nvidia"
  }

  taint {
    key    = "nvidia.com/gpu"
    value  = "present"
    effect = "NO_SCHEDULE"
  }

  scaling_config {
    desired_size = 1
    min_size     = 1
    max_size     = 1
  }

  launch_template {
    id      = aws_launch_template.gpu[0].id
    version = aws_launch_template.gpu[0].latest_version
  }

  depends_on = [
    aws_eks_addon.before_nodes,
    aws_iam_role_policy_attachment.node,
    aws_vpc_endpoint.interface,
    aws_vpc_endpoint.s3,
    aws_route53_resolver_firewall_rule.allow_aws,
  ]
}
