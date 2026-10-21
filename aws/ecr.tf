# The registry inside (ADR 18): this run's ECR repositories, which the nodes
# pull from through the endpoints. The runner copies what it verified into
# them by digest; force_delete lets the run's destroy take the images too.
resource "aws_ecr_repository" "this" {
  for_each             = toset(var.images)
  name                 = "${var.cluster_name}/${each.value}"
  image_tag_mutability = "IMMUTABLE"
  force_delete         = true
}
