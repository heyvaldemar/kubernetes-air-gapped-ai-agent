# What the boundary on GKE promises (ADR 22), checked on a plan against mocked
# Google providers: no project, no credentials, no cost. Run by static check
# "gke"; what no plan shows (a router, a NAT or another route declared
# anywhere) the same check reads from the files, and tests/e2e/gke.sh tries
# on GKE.

mock_provider "google" {
  mock_data "google_project" {
    defaults = { number = "123456789012", project_id = "validation-project" }
  }
}

mock_provider "google-beta" {}

variables {
  project              = "validation-project"
  run_id               = "12345678901"
  cluster_name         = "airgap-12345678901"
  operator_cidrs       = ["203.0.113.7/32"]
  node_service_account = "airgap-node@validation-project.iam.gserviceaccount.com"
}

run "no_route_out" {
  command = plan

  assert {
    condition     = google_compute_network.this.delete_default_routes_on_create && !google_compute_network.this.auto_create_subnetworks
    error_message = "the network is made without its route to the internet, and with no subnets of Google's choosing"
  }
  assert {
    condition     = google_compute_route.google_apis.dest_range == "199.36.153.4/30" && google_compute_route.google_apis.next_hop_gateway == "default-internet-gateway"
    error_message = "the one route out goes to restricted.googleapis.com's four addresses"
  }
  assert {
    condition     = google_compute_subnetwork.nodes.private_ip_google_access
    error_message = "nodes with no external address reach Google's APIs through Private Google Access"
  }
}

run "the_firewall_says_it_again" {
  command = plan

  assert {
    condition     = google_compute_firewall.deny_egress.direction == "EGRESS" && toset(google_compute_firewall.deny_egress.destination_ranges) == toset(["0.0.0.0/0"]) && one(google_compute_firewall.deny_egress.deny).protocol == "all"
    error_message = "egress to anything is denied"
  }
  assert {
    condition     = google_compute_firewall.egress_inside.priority < google_compute_firewall.deny_egress.priority && toset(google_compute_firewall.egress_inside.destination_ranges) == toset(["10.42.0.0/16"])
    error_message = "inside the network's own range, everything is allowed before the denial"
  }
  assert {
    condition     = toset(google_compute_firewall.egress_google_apis.destination_ranges) == toset(["199.36.153.4/30"]) && one(google_compute_firewall.egress_google_apis.allow).protocol == "tcp" && toset(one(google_compute_firewall.egress_google_apis.allow).ports) == toset(["443"])
    error_message = "outside it, HTTPS to restricted.googleapis.com and nothing else"
  }
}

run "no_name_lookup_out" {
  command = plan

  assert {
    condition     = toset(values(local.refused)) == toset(["*.", "*.com.", "*.io.", "*.dev."])
    error_message = "every name is refused, and each top-level domain above an allowed name too"
  }
  assert {
    condition     = alltrue([for r in google_dns_response_policy_rule.refuse : one(r.local_data[0].local_datas).type == "CNAME" && one(r.local_data[0].local_datas).rrdatas == tolist(["refused.boundary.internal."])])
    error_message = "a refused name is answered with a name that does not exist, by Cloud DNS, and goes no further"
  }
  assert {
    condition     = alltrue([for r in google_dns_response_policy_rule.allow : r.behavior == "bypassResponsePolicy"])
    error_message = "the allowed names are let through, not answered by the policy"
  }
  assert {
    condition     = alltrue([for d in values(local.allowed) : contains(["googleapis.com.", "*.googleapis.com.", "gcr.io.", "*.gcr.io.", "pkg.dev.", "*.pkg.dev.", "internal.", "*.internal."], d)])
    error_message = "the names let through are Google's API and registry names and the VPC's internal ones, nothing on the open internet"
  }
  assert {
    condition     = alltrue([for z in google_dns_managed_zone.google : z.visibility == "private"]) && alltrue([for r in google_dns_record_set.google : toset(r.rrdatas) == toset(["199.36.153.4", "199.36.153.5", "199.36.153.6", "199.36.153.7"])])
    error_message = "the names let through are answered inside the network, with restricted.googleapis.com's addresses"
  }
  assert {
    condition     = length(google_dns_response_policy.this.networks) == 1
    error_message = "the response policy is on the network by default"
  }
}

# The one run that shows the DNS check its violation.
run "dns_firewall_off_is_the_violation" {
  command = plan

  variables {
    dns_firewall = false
  }

  assert {
    condition     = length(google_dns_response_policy.this.networks) == 0
    error_message = "with dns_firewall off, the response policy is on no network"
  }
}

run "the_api_from_the_operator_only" {
  command = plan

  assert {
    condition     = one(google_container_cluster.this.private_cluster_config).enable_private_nodes
    error_message = "no node has an external address"
  }
  assert {
    condition     = toset([for c in one(google_container_cluster.this.master_authorized_networks_config).cidr_blocks : c.cidr_block]) == toset(["203.0.113.7/32"]) && one(google_container_cluster.this.master_authorized_networks_config).gcp_public_cidrs_access_enabled == false
    error_message = "the API answers the operator's one address, and not Google Cloud's own ranges"
  }
  assert {
    condition     = one(one(google_container_cluster.this.control_plane_endpoints_config).dns_endpoint_config).allow_external_traffic == false
    error_message = "the DNS-based endpoint takes no traffic from outside"
  }
}

run "an_open_api_is_refused" {
  command = plan

  variables {
    operator_cidrs = ["0.0.0.0/0"]
  }

  expect_failures = [var.operator_cidrs]
}

run "a_name_the_sweep_would_miss_is_refused" {
  command = plan

  variables {
    cluster_name = "reference-platform-12345678901"
  }

  expect_failures = [var.cluster_name]
}

run "the_node" {
  command = plan

  assert {
    condition     = one(google_container_cluster.this.node_pool).node_count == 1
    error_message = "one node"
  }
  assert {
    condition     = one(one(google_container_cluster.this.node_pool).node_config).service_account == var.node_service_account && one(one(one(google_container_cluster.this.node_pool).node_config).workload_metadata_config).mode == "GKE_METADATA"
    error_message = "the node runs as the bootstrap's node account, and a pod sees GKE's metadata server, never the node's credentials"
  }
  assert {
    condition     = one(one(google_container_cluster.this.node_pool).node_config).metadata["disable-legacy-endpoints"] == "true" && one(one(one(google_container_cluster.this.node_pool).node_config).shielded_instance_config).enable_secure_boot
    error_message = "no legacy metadata endpoints, and secure boot"
  }
}

run "network_policies_are_enforced" {
  command = plan

  assert {
    condition     = google_container_cluster.this.datapath_provider == "ADVANCED_DATAPATH"
    error_message = "Dataplane V2 enforces NetworkPolicies; without it the agent's would be accepted and enforce nothing"
  }
}

run "the_registry_inside_is_read_by_two" {
  command = plan

  assert {
    condition     = google_artifact_registry_repository.inside.format == "DOCKER" && one(google_artifact_registry_repository.inside.docker_config).immutable_tags
    error_message = "the run's own repository, its tags immutable"
  }
  assert {
    condition     = google_artifact_registry_repository_iam_member.node.role == "roles/artifactregistry.reader" && google_artifact_registry_repository_iam_member.kyverno.role == "roles/artifactregistry.reader"
    error_message = "the nodes and Kyverno read; neither can write"
  }
  assert {
    condition     = google_artifact_registry_repository_iam_member.kyverno.member == "principal://iam.googleapis.com/projects/123456789012/locations/global/workloadIdentityPools/validation-project.svc.id.goog/subject/ns/kyverno/sa/kyverno-admission-controller"
    error_message = "Kyverno reads as its admission controller's service account, and no other pod does"
  }
}
