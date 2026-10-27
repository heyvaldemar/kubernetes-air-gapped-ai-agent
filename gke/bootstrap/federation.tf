# GitHub's OIDC token for a job, exchanged for a short-lived Google credential
# (ADR 22). No key is stored anywhere: not in the repository, not in a
# secret, not on the runner after the job.
#
# The provider admits one subject: a job on main of this repository, in the
# immutable form the repository's OIDC customization uses
# (use_immutable_subject), the owner and the repository by their numeric ids.
# A rule written with the names matches nothing (ADR 14, "A subject written
# by name"), and a renamed or re-created repository of the same name is not
# this one. A branch, a pull request, a tag and an environment each carry
# another subject and are refused before any service account is asked.
#
# Within that subject, each service account answers one workflow file: the
# run's to gke.yml, the sweep's to gke-sweep.yml. A job in any other workflow
# on main gets nothing; the provider refuses its token first.

locals {
  repository = "heyvaldemar/kubernetes-air-gapped-ai-agent"
  subject    = "repo:heyvaldemar@10498744/kubernetes-air-gapped-ai-agent@1421238353:ref:refs/heads/main"
  workflows = {
    create = "${local.repository}/.github/workflows/gke.yml@refs/heads/main"
    sweep  = "${local.repository}/.github/workflows/gke-sweep.yml@refs/heads/main"
  }
}

resource "google_iam_workload_identity_pool" "github" {
  workload_identity_pool_id = "github"
  display_name              = "GitHub Actions"
  description               = "Jobs of heyvaldemar/kubernetes-air-gapped-ai-agent on main (ADR 22)."
  depends_on                = [google_project_service.free]
}

resource "google_iam_workload_identity_pool_provider" "github" {
  workload_identity_pool_id          = google_iam_workload_identity_pool.github.workload_identity_pool_id
  workload_identity_pool_provider_id = "kubernetes-air-gapped-ai-agent"
  display_name                       = "kubernetes-air-gapped-ai-agent"
  description                        = "Main of the flagship, the run's workflow and the sweep's (ADR 22)."
  attribute_mapping = {
    "google.subject"         = "assertion.sub"
    "attribute.workflow_ref" = "assertion.workflow_ref"
  }
  attribute_condition = "assertion.sub == '${local.subject}' && assertion.workflow_ref in ['${local.workflows.create}', '${local.workflows.sweep}']"
  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

resource "google_service_account_iam_member" "federated" {
  for_each           = { create = google_service_account.create.name, sweep = google_service_account.sweep.name }
  service_account_id = each.value
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.workflow_ref/${local.workflows[each.key]}"
}
