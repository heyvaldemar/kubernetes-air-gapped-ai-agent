# The registry inside (ADR 22): this run's Artifact Registry repository, which
# the nodes pull from through restricted.googleapis.com. Every image the run
# carries goes under it by its original path, and the bundle is loaded into
# it only after its signature and checksums verify (scripts/bundle.sh load).
# Tags are immutable. The run's destroy deletes the repository with what it
# holds.
#
# Two identities may read it, and no other: the nodes' service account, for
# the kubelet, and Kyverno's admission controller, by its Kubernetes service
# account through Workload Identity Federation for GKE, to read signatures
# and AI-BOMs. Neither has any role in the project; each reads this
# repository and nothing else.

data "google_project" "this" {
  project_id = var.project
}

resource "google_artifact_registry_repository" "inside" {
  repository_id = var.cluster_name
  location      = var.region
  format        = "DOCKER"
  description   = "The registry inside for run ${var.run_id} (ADR 22)."

  docker_config {
    immutable_tags = true
  }
}

resource "google_artifact_registry_repository_iam_member" "node" {
  repository = google_artifact_registry_repository.inside.name
  location   = var.region
  role       = "roles/artifactregistry.reader"
  member     = "serviceAccount:${var.node_service_account}"
}

# The project's GKE workload pool exists once a cluster with Workload
# Identity does: the binding waits for the cluster.
resource "google_artifact_registry_repository_iam_member" "kyverno" {
  repository = google_artifact_registry_repository.inside.name
  location   = var.region
  role       = "roles/artifactregistry.reader"
  member     = "principal://iam.googleapis.com/projects/${data.google_project.this.number}/locations/global/workloadIdentityPools/${var.project}.svc.id.goog/subject/ns/kyverno/sa/kyverno-admission-controller"
  depends_on = [google_container_cluster.this]
}
