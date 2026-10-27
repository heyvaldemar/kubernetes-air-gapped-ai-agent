# The repository variables .github/workflows/gke.yml and gke-sweep.yml read.
# None of them is a secret.

output "workload_identity_provider" {
  description = "GKE_WORKLOAD_IDENTITY_PROVIDER"
  value       = google_iam_workload_identity_pool_provider.github.name
}

output "create_service_account" {
  description = "GKE_CREATE_SERVICE_ACCOUNT"
  value       = google_service_account.create.email
}

output "sweep_service_account" {
  description = "GKE_SWEEP_SERVICE_ACCOUNT"
  value       = google_service_account.sweep.email
}

output "node_service_account" {
  description = "GKE_NODE_SERVICE_ACCOUNT"
  value       = google_service_account.node.email
}

output "state_bucket" {
  description = "GKE_STATE_BUCKET"
  value       = local.billed ? google_storage_bucket.state[0].name : null
}

output "project_number" {
  value = data.google_project.this.number
}
