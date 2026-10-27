# A network with no way out (ADR 22). A new VPC on Google Cloud comes with a
# route for 0.0.0.0/0 to the internet gateway; this one is made without it.
# Its one route out goes to restricted.googleapis.com's four addresses, where
# Google serves the APIs VPC Service Controls supports and nothing else: no
# App Engine, no Cloud Run, nobody's website. Google announces that range
# inside its own network only. No Cloud NAT, no Cloud Router, no external
# address is declared anywhere in this directory, and static check "gke"
# fails if one is.
#
# The firewall says the same again: egress to anything outside the network's
# own range is denied, but HTTPS to those four addresses.

locals {
  nodes_cidr    = cidrsubnet(var.vpc_cidr, 4, 0)
  services_cidr = cidrsubnet(var.vpc_cidr, 4, 1)
  pods_cidr     = cidrsubnet(var.vpc_cidr, 1, 1)
  # restricted.googleapis.com
  google_apis          = "199.36.153.4/30"
  google_api_addresses = ["199.36.153.4", "199.36.153.5", "199.36.153.6", "199.36.153.7"]
}

resource "google_compute_network" "this" {
  name                            = var.cluster_name
  description                     = "The boundary on GKE (ADR 22), run ${var.run_id}: no route out but to Google's restricted APIs."
  auto_create_subnetworks         = false
  delete_default_routes_on_create = true
  routing_mode                    = "REGIONAL"
}

# Private Google Access lets a node with no external address use the route
# below; without it the four addresses would be as far as the internet.
resource "google_compute_subnetwork" "nodes" {
  name                     = var.cluster_name
  network                  = google_compute_network.this.id
  region                   = var.region
  ip_cidr_range            = local.nodes_cidr
  private_ip_google_access = true

  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = local.pods_cidr
  }

  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = local.services_cidr
  }
}

resource "google_compute_route" "google_apis" {
  name             = "${var.cluster_name}-google-apis"
  description      = "restricted.googleapis.com, the one way out of the network (ADR 22)."
  network          = google_compute_network.this.name
  dest_range       = local.google_apis
  next_hop_gateway = "default-internet-gateway"
  priority         = 1000
}

resource "google_compute_firewall" "deny_egress" {
  name               = "${var.cluster_name}-deny-egress"
  description        = "Nothing leaves the network but what the rules above this one allow (ADR 22)."
  network            = google_compute_network.this.name
  direction          = "EGRESS"
  priority           = 65534
  destination_ranges = ["0.0.0.0/0"]

  deny {
    protocol = "all"
  }
}

resource "google_compute_firewall" "egress_inside" {
  name               = "${var.cluster_name}-egress-inside"
  description        = "The nodes, the pods, the services and the cluster's control plane, which answers inside the node subnet."
  network            = google_compute_network.this.name
  direction          = "EGRESS"
  priority           = 1000
  destination_ranges = [var.vpc_cidr]

  allow {
    protocol = "all"
  }
}

resource "google_compute_firewall" "egress_google_apis" {
  name               = "${var.cluster_name}-egress-google-apis"
  description        = "HTTPS to restricted.googleapis.com, and nothing else outside the network."
  network            = google_compute_network.this.name
  direction          = "EGRESS"
  priority           = 1000
  destination_ranges = [local.google_apis]

  allow {
    protocol = "tcp"
    ports    = ["443"]
  }
}
