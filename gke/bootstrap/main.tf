data "google_project" "this" {
  project_id = var.project
}

locals {
  billed = var.billing_account != null
  # What the federation, the service accounts and the budget call. None of
  # these needs a billing account to be turned on.
  free_apis = [
    "billingbudgets.googleapis.com",
    "cloudbilling.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "monitoring.googleapis.com",
    "serviceusage.googleapis.com",
    "sts.googleapis.com",
  ]
  # What a run makes. Each of these is turned on only once the project has a
  # billing account, and nothing a run makes exists before then.
  billed_apis = [
    "artifactregistry.googleapis.com",
    "compute.googleapis.com",
    "container.googleapis.com",
    "dns.googleapis.com",
    "storage.googleapis.com",
  ]
}

resource "google_project_service" "free" {
  for_each           = toset(local.free_apis)
  service            = each.value
  disable_on_destroy = false
}

resource "google_billing_project_info" "this" {
  count           = local.billed ? 1 : 0
  project         = data.google_project.this.project_id
  billing_account = var.billing_account
}

resource "google_project_service" "billed" {
  for_each           = local.billed ? toset(local.billed_apis) : toset([])
  service            = each.value
  disable_on_destroy = false
  depends_on         = [google_billing_project_info.this]
}

# One Terraform state per run under airgap-runs/, beside the run's variables;
# this configuration's own under bootstrap/, which no run can read or write.
resource "google_storage_bucket" "state" {
  count                       = local.billed ? 1 : 0
  name                        = "${var.project}-airgap-tfstate"
  location                    = upper(var.region)
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = false

  versioning {
    enabled = true
  }

  lifecycle_rule {
    condition {
      num_newer_versions = 5
      with_state         = "ARCHIVED"
    }
    action {
      type = "Delete"
    }
  }

  depends_on = [google_project_service.billed]
}

# The three identities a run uses. No key is made for any of them, and none
# can be: the organization enforces iam.disableServiceAccountKeyCreation.
resource "google_service_account" "create" {
  account_id   = "airgap-create"
  display_name = "GKE boundary run: creates one run and destroys it"
  description  = "Impersonated by .github/workflows/gke.yml on main through the github pool (ADR 22). Holds airgapRunCreate and GKE's admin role in this project, and nothing outside it."
}

resource "google_service_account" "sweep" {
  account_id   = "airgap-sweep"
  display_name = "GKE boundary run: deletes what a run left"
  description  = "Impersonated by .github/workflows/gke-sweep.yml on main through the github pool (ADR 22). Lists, reads and deletes; creates nothing."
}

resource "google_service_account" "node" {
  account_id   = "airgap-node"
  display_name = "GKE boundary run: the nodes"
  description  = "The run's GKE nodes (ADR 22). No role in the project: each run lets it read that run's registry, and nothing else."
}

# What a run's Terraform makes and destroys besides the cluster, and what it
# reads to look for residue. Kept as a list a reviewer can read; a permission
# Terraform turns out to need is added here with the run that showed it.
resource "google_project_iam_custom_role" "create" {
  role_id     = "airgapRunCreate"
  title       = "GKE boundary run: create and destroy"
  description = "The network, its DNS, the registry inside, and reading for residue (ADR 22). The cluster itself is roles/container.admin."
  permissions = [
    # The network, its one route to Google's APIs, and its firewall.
    "compute.firewalls.create",
    "compute.firewalls.delete",
    "compute.firewalls.get",
    "compute.firewalls.list",
    "compute.globalOperations.get",
    "compute.networks.create",
    "compute.networks.delete",
    "compute.networks.get",
    "compute.networks.list",
    "compute.networks.updatePolicy",
    "compute.networks.use",
    "compute.regionOperations.get",
    "compute.routes.create",
    "compute.routes.delete",
    "compute.routes.get",
    "compute.routes.list",
    "compute.subnetworks.create",
    "compute.subnetworks.delete",
    "compute.subnetworks.get",
    "compute.subnetworks.list",
    "compute.subnetworks.setPrivateIpGoogleAccess",
    "compute.subnetworks.use",
    "compute.zoneOperations.get",
    # What GKE makes for a cluster, read for residue after the destroy.
    "compute.addresses.list",
    "compute.autoscalers.list",
    "compute.backendServices.list",
    "compute.disks.list",
    "compute.forwardingRules.list",
    "compute.globalAddresses.list",
    "compute.globalForwardingRules.list",
    "compute.healthChecks.list",
    "compute.instanceGroupManagers.list",
    "compute.instanceGroups.list",
    "compute.instanceTemplates.list",
    "compute.instances.list",
    "compute.networkEndpointGroups.list",
    "compute.targetPools.list",
    # The private zones for Google's API names, and the response policy that
    # refuses every other name.
    "dns.changes.create",
    "dns.changes.get",
    "dns.managedZones.create",
    "dns.managedZones.delete",
    "dns.managedZones.get",
    "dns.managedZones.list",
    "dns.managedZones.update",
    "dns.networks.bindDNSResponsePolicy",
    "dns.networks.bindPrivateDNSZone",
    "dns.resourceRecordSets.create",
    "dns.resourceRecordSets.delete",
    "dns.resourceRecordSets.get",
    "dns.resourceRecordSets.list",
    "dns.resourceRecordSets.update",
    "dns.responsePolicies.create",
    "dns.responsePolicies.delete",
    "dns.responsePolicies.get",
    "dns.responsePolicies.list",
    "dns.responsePolicies.update",
    "dns.responsePolicyRules.create",
    "dns.responsePolicyRules.delete",
    "dns.responsePolicyRules.get",
    "dns.responsePolicyRules.list",
    "dns.responsePolicyRules.update",
    # The registry inside: the run's own repository, what crosses into it,
    # and who may read it.
    "artifactregistry.dockerimages.get",
    "artifactregistry.dockerimages.list",
    "artifactregistry.repositories.create",
    "artifactregistry.repositories.delete",
    "artifactregistry.repositories.downloadArtifacts",
    "artifactregistry.repositories.get",
    "artifactregistry.repositories.getIamPolicy",
    "artifactregistry.repositories.list",
    "artifactregistry.repositories.setIamPolicy",
    "artifactregistry.repositories.uploadArtifacts",
    "artifactregistry.tags.create",
    "artifactregistry.tags.get",
    "artifactregistry.tags.list",
    "artifactregistry.tags.update",
    "artifactregistry.versions.get",
    "artifactregistry.versions.list",
    "resourcemanager.projects.get",
    "serviceusage.services.use",
  ]
}

# Delete-only, with two exceptions a delete cannot go without: a response
# policy is taken off its network (an update of the policy, which binds the
# network) before it can be deleted, and deleting a firewall rule or a route
# asks for the network's updatePolicy. It lists everything scripts/gke.sh
# what() lists, and gcloud's managed-group listing reads the groups and
# their autoscalers too.
resource "google_project_iam_custom_role" "sweep" {
  role_id     = "airgapRunSweep"
  title       = "GKE boundary run: sweep"
  description = "Lists, reads and deletes what a run left (ADR 22). Creates nothing."
  permissions = [
    "artifactregistry.repositories.delete",
    "artifactregistry.repositories.get",
    "artifactregistry.repositories.list",
    "compute.autoscalers.list",
    "compute.disks.delete",
    "compute.disks.get",
    "compute.disks.list",
    "compute.firewalls.delete",
    "compute.firewalls.get",
    "compute.firewalls.list",
    "compute.forwardingRules.list",
    "compute.globalForwardingRules.list",
    "compute.globalOperations.get",
    "compute.instanceGroupManagers.list",
    "compute.instanceGroups.list",
    "compute.instanceTemplates.list",
    "compute.instances.list",
    "compute.networks.delete",
    "compute.networks.get",
    "compute.networks.list",
    "compute.networks.updatePolicy",
    "compute.regionOperations.get",
    "compute.routes.delete",
    "compute.routes.get",
    "compute.routes.list",
    "compute.subnetworks.delete",
    "compute.subnetworks.get",
    "compute.subnetworks.list",
    "compute.zoneOperations.get",
    "container.clusters.delete",
    "container.clusters.get",
    "container.clusters.list",
    "container.operations.get",
    "container.operations.list",
    "dns.managedZones.delete",
    "dns.managedZones.get",
    "dns.managedZones.list",
    "dns.networks.bindDNSResponsePolicy",
    "dns.resourceRecordSets.delete",
    "dns.resourceRecordSets.list",
    "dns.responsePolicies.delete",
    "dns.responsePolicies.get",
    "dns.responsePolicies.list",
    "dns.responsePolicies.update",
    "dns.responsePolicyRules.delete",
    "dns.responsePolicyRules.get",
    "dns.responsePolicyRules.list",
    "resourcemanager.projects.get",
    "serviceusage.services.use",
  ]
}

resource "google_project_iam_member" "create" {
  for_each = { custom = google_project_iam_custom_role.create.name, gke = "roles/container.admin" }
  project  = data.google_project.this.project_id
  role     = each.value
  member   = google_service_account.create.member
}

resource "google_project_iam_member" "sweep" {
  project = data.google_project.this.project_id
  role    = google_project_iam_custom_role.sweep.name
  member  = google_service_account.sweep.member
}

# The cluster runs as the node account, and the run may say so for that
# account alone: it cannot start a cluster as anything else.
resource "google_service_account_iam_member" "create_acts_as_node" {
  service_account_id = google_service_account.node.name
  role               = "roles/iam.serviceAccountUser"
  member             = google_service_account.create.member
}

# A run reads and writes its own state and variables, under airgap-runs/ and
# nowhere else in the bucket.
resource "google_storage_bucket_iam_member" "create_state" {
  count  = local.billed ? 1 : 0
  bucket = google_storage_bucket.state[0].name
  role   = "roles/storage.objectUser"
  member = google_service_account.create.member
  condition {
    title       = "airgap-runs-only"
    description = "The runs' own states and variables; never bootstrap/."
    expression  = "resource.name == \"projects/_/buckets/${google_storage_bucket.state[0].name}\" || resource.name.startsWith(\"projects/_/buckets/${google_storage_bucket.state[0].name}/objects/airgap-runs/\")"
  }
}
