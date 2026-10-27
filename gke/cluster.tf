# GKE in the closed network (ADR 22). A zonal cluster, the kind GKE's free
# tier covers, with private nodes: no node has an external address. The
# nodes reach the control plane at its private endpoint, inside the node
# subnet; the operator, the runner, through the external endpoint from its
# own address only (/32), and not from Google Cloud's own ranges either. The
# DNS-based endpoint takes no traffic from outside.
#
# Dataplane V2 enforces the agent's NetworkPolicies, as kindnet does on kind
# and the VPC CNI does on EKS: without it they would be accepted and enforce
# nothing. Workload Identity Federation for GKE gives Kyverno a Google
# identity of its own (registry.tf) and keeps every pod off the node's
# credentials. Logging and monitoring are off: nothing on the node sends
# anything to Cloud Logging, and the node keeps its CPU for the model.

resource "google_container_cluster" "this" {
  name                = var.cluster_name
  description         = "The boundary on GKE (ADR 22), run ${var.run_id}."
  location            = var.zone
  network             = google_compute_network.this.id
  subnetwork          = google_compute_subnetwork.nodes.id
  deletion_protection = false
  min_master_version  = var.kubernetes_version

  release_channel {
    channel = var.release_channel
  }

  networking_mode   = "VPC_NATIVE"
  datapath_provider = "ADVANCED_DATAPATH"

  ip_allocation_policy {
    cluster_secondary_range_name  = "pods"
    services_secondary_range_name = "services"
  }

  # A pod's traffic leaves with the pod's own address, not its node's, so
  # the firewall can hold private.googleapis.com to the node alone.
  default_snat_status {
    disabled = true
  }

  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = false
  }

  master_authorized_networks_config {
    gcp_public_cidrs_access_enabled = false
    dynamic "cidr_blocks" {
      for_each = var.operator_cidrs
      content {
        cidr_block   = cidr_blocks.value
        display_name = "operator"
      }
    }
  }

  control_plane_endpoints_config {
    dns_endpoint_config {
      allow_external_traffic = false
    }
  }

  workload_identity_config {
    workload_pool = "${var.project}.svc.id.goog"
  }

  logging_config {
    enable_components = []
  }

  monitoring_config {
    enable_components = []
    managed_prometheus {
      enabled = false
    }
  }

  security_posture_config {
    mode               = "DISABLED"
    vulnerability_mode = "VULNERABILITY_DISABLED"
  }

  addons_config {
    http_load_balancing {
      disabled = true
    }
    # Pods ask kube-dns, as on kind and EKS, and the agent's NetworkPolicies
    # name kube-dns's pods for DNS. GKE turned NodeLocal DNSCache on in the
    # second run (40555921881), which answers on the node instead.
    dns_cache_config {
      enabled = false
    }
  }

  # One node pool, declared with the cluster, so no default pool is made
  # and removed on the way.
  node_pool {
    name       = "nodes"
    node_count = 1

    management {
      auto_repair  = true
      auto_upgrade = true
    }

    node_config {
      machine_type    = var.node_machine_type
      image_type      = "COS_CONTAINERD"
      disk_type       = "pd-balanced"
      disk_size_gb    = 50
      service_account = var.node_service_account
      oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]
      resource_labels = local.labels
      metadata = {
        disable-legacy-endpoints = "true"
      }

      # A pod sees GKE's metadata server, which hands it its own identity
      # if it has one, and never the node's.
      workload_metadata_config {
        mode = "GKE_METADATA"
      }

      shielded_instance_config {
        enable_secure_boot          = true
        enable_integrity_monitoring = true
      }
    }
  }

  depends_on = [
    google_compute_route.google_apis,
    google_compute_route.google_images,
    google_compute_firewall.egress_inside,
    google_compute_firewall.egress_google_apis,
    google_compute_firewall.egress_google_images,
    google_dns_record_set.google,
    google_dns_record_set.google_names,
    google_dns_response_policy_rule.allow,
  ]
}
