# A network with no way out (ADR 22). A new VPC on Google Cloud comes with a
# route for 0.0.0.0/0 to the internet gateway; this one is made without it.
# Its two routes out go to Google's two front doors for its APIs, which Google
# announces inside its own network only:
#
#   restricted.googleapis.com  the APIs VPC Service Controls supports, and
#                              nothing else: no App Engine, no Cloud Run,
#                              nobody's website. Every pod and the node use it,
#                              for every API and the run's own registry.
#   private.googleapis.com     most Google APIs, and App Engine, Cloud Run and
#                              Cloud Functions too. GKE's own images come from
#                              here: a node pulling one through the restricted
#                              door was refused (403, run 40550142699), while
#                              the same request as the node's account over the
#                              public path was answered. The firewall lets the
#                              node's own address reach it, and no pod.
#
# No Cloud NAT, no Cloud Router, no external address is declared anywhere in
# this directory, and static check "gke" fails if one is. The firewall says
# the same again: egress to anything outside the network's own range is
# denied, but HTTPS to those two ranges, the second from the node subnet only.
# Pods keep their own addresses on the way out (the cluster's default SNAT is
# off, cluster.tf), so the firewall can tell a pod from its node.

locals {
  nodes_cidr    = cidrsubnet(var.vpc_cidr, 4, 0)
  services_cidr = cidrsubnet(var.vpc_cidr, 4, 1)
  pods_cidr     = cidrsubnet(var.vpc_cidr, 1, 1)
  # restricted.googleapis.com
  google_apis          = "199.36.153.4/30"
  google_api_addresses = ["199.36.153.4", "199.36.153.5", "199.36.153.6", "199.36.153.7"]
  # private.googleapis.com, for GKE's own images, from the node alone
  google_images          = "199.36.153.8/30"
  google_image_addresses = ["199.36.153.8", "199.36.153.9", "199.36.153.10", "199.36.153.11"]
}

resource "google_compute_network" "this" {
  name                            = var.cluster_name
  description                     = "The boundary on GKE (ADR 22), run ${var.run_id}: no route out but to Google's API front doors."
  auto_create_subnetworks         = false
  delete_default_routes_on_create = true
  routing_mode                    = "REGIONAL"
}

# Private Google Access lets a node with no external address use the routes
# below; without it those addresses would be as far as the internet.
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

# The next hop is named the default internet gateway; Google's documentation
# says what is sent to its API ranges that way stays inside its network.
resource "google_compute_route" "google_apis" {
  name             = "${var.cluster_name}-google-apis"
  description      = "restricted.googleapis.com, the way out for every pod and the node (ADR 22)."
  network          = google_compute_network.this.name
  dest_range       = local.google_apis
  next_hop_gateway = "default-internet-gateway"
  priority         = 1000
}

resource "google_compute_route" "google_images" {
  name             = "${var.cluster_name}-google-images"
  description      = "private.googleapis.com, for GKE's own images; the firewall lets the node subnet alone use it (ADR 22)."
  network          = google_compute_network.this.name
  dest_range       = local.google_images
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
  description        = "HTTPS to restricted.googleapis.com, from the node and its pods."
  network            = google_compute_network.this.name
  direction          = "EGRESS"
  priority           = 1000
  destination_ranges = [local.google_apis]

  allow {
    protocol = "tcp"
    ports    = ["443"]
  }
}

resource "google_compute_firewall" "egress_google_images" {
  name               = "${var.cluster_name}-egress-google-images"
  description        = "HTTPS to private.googleapis.com, from the node subnet's own addresses and from no pod."
  network            = google_compute_network.this.name
  direction          = "EGRESS"
  priority           = 1000
  source_ranges      = [local.nodes_cidr]
  destination_ranges = [local.google_images]

  allow {
    protocol = "tcp"
    ports    = ["443"]
  }
}
