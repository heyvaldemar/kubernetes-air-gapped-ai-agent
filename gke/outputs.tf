output "cluster_name" {
  value = google_container_cluster.this.name
}

output "location" {
  value = google_container_cluster.this.location
}

output "registry" {
  description = "The registry inside: Artifact Registry's Docker host in the region."
  value       = "${var.region}-docker.pkg.dev"
}

output "inside" {
  description = "The registry inside for scripts/inside.sh: this run's repository."
  value       = "${var.region}-docker.pkg.dev/${var.project}/${google_artifact_registry_repository.inside.repository_id}"
}

output "network" {
  value = google_compute_network.this.name
}

output "google_apis" {
  description = "restricted.googleapis.com, the range outside the network every pod and the node may reach."
  value       = local.google_apis
}

output "google_images" {
  description = "private.googleapis.com, for GKE's own images, which the node may reach and no pod may."
  value       = local.google_images
}

output "dns_firewall" {
  value = var.dns_firewall
}
