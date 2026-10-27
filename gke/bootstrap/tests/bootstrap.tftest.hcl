# What the GKE run's standing parts promise (ADR 22), checked on a plan
# against a mocked Google provider (an apply against mocks is a plan with the
# computed values filled in): who may get a credential, what each
# identity may do, where the run's state lives, and the budget. Run by static
# check "gke".

mock_provider "google" {
  mock_data "google_project" {
    defaults = { number = "123456789012", project_id = "validation-project" }
  }
  # The provider checks these shapes even against a mock.
  mock_resource "google_service_account" {
    defaults = {
      name   = "projects/validation-project/serviceAccounts/airgap@validation-project.iam.gserviceaccount.com"
      email  = "airgap@validation-project.iam.gserviceaccount.com"
      member = "serviceAccount:airgap@validation-project.iam.gserviceaccount.com"
    }
  }
  mock_resource "google_iam_workload_identity_pool" {
    defaults = { name = "projects/123456789012/locations/global/workloadIdentityPools/github" }
  }
  mock_resource "google_project_iam_custom_role" {
    defaults = { name = "projects/validation-project/roles/airgapRun" }
  }
  mock_resource "google_monitoring_notification_channel" {
    defaults = { id = "projects/validation-project/notificationChannels/1", name = "projects/validation-project/notificationChannels/1" }
  }
}

variables {
  project         = "validation-project"
  billing_account = "000000-000000-000000"
  alert_email     = "alerts@example.com"
}

run "one_subject_two_workflows" {
  command = apply

  assert {
    condition     = google_iam_workload_identity_pool_provider.github.attribute_condition == "assertion.sub == 'repo:heyvaldemar@10498744/kubernetes-air-gapped-ai-agent@1421238353:ref:refs/heads/main' && assertion.workflow_ref in ['heyvaldemar/kubernetes-air-gapped-ai-agent/.github/workflows/gke.yml@refs/heads/main', 'heyvaldemar/kubernetes-air-gapped-ai-agent/.github/workflows/gke-sweep.yml@refs/heads/main']"
    error_message = "the provider admits main of this repository, by its immutable subject, from the run's workflow or the sweep's, and nothing else"
  }
  assert {
    condition     = one(google_iam_workload_identity_pool_provider.github.oidc).issuer_uri == "https://token.actions.githubusercontent.com"
    error_message = "the tokens are GitHub's"
  }
  assert {
    condition     = endswith(google_service_account_iam_member.federated["create"].member, "/attribute.workflow_ref/heyvaldemar/kubernetes-air-gapped-ai-agent/.github/workflows/gke.yml@refs/heads/main") && endswith(google_service_account_iam_member.federated["sweep"].member, "/attribute.workflow_ref/heyvaldemar/kubernetes-air-gapped-ai-agent/.github/workflows/gke-sweep.yml@refs/heads/main")
    error_message = "each service account answers its own workflow file and no other"
  }
  assert {
    condition     = alltrue([for m in google_service_account_iam_member.federated : m.role == "roles/iam.workloadIdentityUser"])
    error_message = "a workflow may act as its account; it gets no other role on it"
  }
}

run "the_sweep_creates_nothing" {
  command = apply

  assert {
    condition = alltrue([
      for p in google_project_iam_custom_role.sweep.permissions :
      can(regex("\\.(list|get|delete)$", p)) || contains(["dns.changes.create", "dns.responsePolicies.update", "dns.networks.bindDNSResponsePolicy", "serviceusage.services.use"], p)
    ])
    error_message = "the sweep lists, reads and deletes; the only exceptions are the DNS change a zone's delete needs and taking a response policy off its network"
  }
}

run "the_run_cannot_reach_past_its_project" {
  command = apply

  assert {
    condition     = alltrue([for p in google_project_iam_custom_role.create.permissions : !startswith(p, "iam.") && !startswith(p, "resourcemanager.projects.set") && !startswith(p, "orgpolicy.") && !startswith(p, "billing.")])
    error_message = "the run's role grants no identity, no project policy, no organization policy and no billing"
  }
  assert {
    condition     = toset(keys(google_project_iam_member.create)) == toset(["custom", "gke"]) && google_project_iam_member.create["gke"].role == "roles/container.admin" && google_project_iam_member.create["custom"].role == google_project_iam_custom_role.create.name
    error_message = "the run holds its own role and GKE's admin role in the project, and no other"
  }
  assert {
    condition     = google_service_account_iam_member.create_acts_as_node.role == "roles/iam.serviceAccountUser" && google_service_account_iam_member.create_acts_as_node.member == google_service_account.create.member
    error_message = "the run may start a cluster as the node account, and only as that one"
  }
}

run "the_runs_state_and_the_bootstrap_apart" {
  command = apply

  assert {
    condition     = google_storage_bucket.state[0].public_access_prevention == "enforced" && google_storage_bucket.state[0].uniform_bucket_level_access && one(google_storage_bucket.state[0].versioning).enabled
    error_message = "the state bucket is never public, has no per-object ACLs, and keeps versions"
  }
  assert {
    condition     = strcontains(one(google_storage_bucket_iam_member.create_state[0].condition).expression, "/objects/airgap-runs/\")")
    error_message = "a run reads and writes under airgap-runs/ only, never the bootstrap's own state"
  }
}

run "the_budget" {
  command = apply

  assert {
    condition     = toset([for t in google_billing_budget.this[0].threshold_rules : "${t.threshold_percent}/${t.spend_basis}"]) == toset(["0.5/CURRENT_SPEND", "0.9/CURRENT_SPEND", "1/CURRENT_SPEND", "1/FORECASTED_SPEND"])
    error_message = "alerts at half, 90% and all of it spent, and at a forecast of all of it"
  }
  assert {
    condition     = one(google_billing_budget.this[0].budget_filter).credit_types_treatment == "EXCLUDE_ALL_CREDITS" && one(google_billing_budget.this[0].budget_filter).projects == toset(["projects/123456789012"])
    error_message = "the budget counts this project's spend before any credit"
  }
  assert {
    condition     = one(one(google_billing_budget.this[0].amount).specified_amount).units == "10"
    error_message = "ten a month"
  }
}

run "nothing_billed_before_billing" {
  command = apply

  variables {
    billing_account = null
    alert_email     = null
  }

  assert {
    condition     = length(google_billing_project_info.this) == 0 && length(google_project_service.billed) == 0 && length(google_storage_bucket.state) == 0 && length(google_billing_budget.this) == 0
    error_message = "with no billing account, nothing billed is turned on or made"
  }
}
