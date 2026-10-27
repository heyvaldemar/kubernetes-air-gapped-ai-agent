# The boundary on GKE (ADR 22), one run at a time: everything here is made by
# a run and destroyed by it, in the validation project's one region. The
# project's standing parts (the federation, the service accounts, the state
# bucket, the budget) are gke/bootstrap/, applied once by the maintainer.
terraform {
  required_version = ">= 1.10"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 8.8"
    }
    # A response policy rule that lets a name through (behavior
    # bypassResponsePolicy) is in the beta provider only.
    google-beta = {
      source  = "hashicorp/google-beta"
      version = "~> 8.8"
    }
  }
}

locals {
  labels = {
    "airgap-project" = "kubernetes-air-gapped-ai-agent"
    "airgap-cluster" = var.cluster_name
    "run-id"         = var.run_id
    "managed-by"     = "terraform"
  }
}

provider "google" {
  project        = var.project
  region         = var.region
  default_labels = local.labels
}

provider "google-beta" {
  project        = var.project
  region         = var.region
  default_labels = local.labels
}
