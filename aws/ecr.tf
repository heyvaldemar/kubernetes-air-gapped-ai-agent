# The registry inside (ADR 18): this run's ECR repositories, which the nodes
# pull from through the endpoints, each under the cluster's name by the
# image's original path. The bundle is loaded into them after its signature
# and checksums verify (scripts/bundle.sh load); force_delete lets the run's
# destroy take the images too.
resource "aws_ecr_repository" "this" {
  for_each             = toset(var.images)
  name                 = "${var.cluster_name}/${each.value}"
  image_tag_mutability = "IMMUTABLE"
  force_delete         = true
}
