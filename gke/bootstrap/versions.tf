# The standing parts of the run on GKE (ADR 22), applied once from the
# maintainer's own login, never by CI: the APIs, the billing link and its
# budget, the state bucket, the federation GitHub's token is exchanged
# through, and the three service accounts a run uses. Everything a run makes
# is in gke/ and lives for the length of that run.
#
# The state starts local (a backend_override.tf with backend "local", kept
# out of git) and moves into the state bucket under bootstrap/ once the
# bucket exists: terraform init -migrate-state -backend-config=bucket=<it>.
terraform {
  required_version = ">= 1.10"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 8.8"
    }
  }

  backend "gcs" {
    prefix = "bootstrap"
  }
}

# The budget API is called with the maintainer's user credential, which needs
# a project to bill the call to: this one.
provider "google" {
  project               = var.project
  region                = var.region
  user_project_override = true
  billing_project       = var.project
  default_labels = {
    "airgap-project" = "kubernetes-air-gapped-ai-agent"
    "managed-by"     = "terraform"
  }
}
