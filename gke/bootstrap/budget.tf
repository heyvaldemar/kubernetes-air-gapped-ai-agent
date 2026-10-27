# The project's monthly budget (ADR 22): alerts at half, 90% and all of it
# spent, and when the month's forecast reaches all of it. Spend is counted
# before any credit, the GKE free tier's included, so the alerts read what
# the runs would cost without one. The billing account's administrators get
# the alerts by default, and the address given at apply gets them too.
#
# A budget alerts; it stops nothing. What stops a run that is left behind is
# the run's own destroy, then the next run's sweep, then the daily sweep.

resource "google_monitoring_notification_channel" "budget" {
  count        = local.billed && var.alert_email != null ? 1 : 0
  display_name = "GKE boundary run budget"
  type         = "email"
  labels = {
    email_address = var.alert_email
  }
  depends_on = [google_project_service.free]
}

resource "google_billing_budget" "this" {
  count           = local.billed ? 1 : 0
  billing_account = var.billing_account
  display_name    = "${var.project} monthly"

  budget_filter {
    projects               = ["projects/${data.google_project.this.number}"]
    calendar_period        = "MONTH"
    credit_types_treatment = "EXCLUDE_ALL_CREDITS"
  }

  amount {
    specified_amount {
      units = tostring(var.budget_amount)
    }
  }

  threshold_rules {
    threshold_percent = 0.5
    spend_basis       = "CURRENT_SPEND"
  }
  threshold_rules {
    threshold_percent = 0.9
    spend_basis       = "CURRENT_SPEND"
  }
  threshold_rules {
    threshold_percent = 1.0
    spend_basis       = "CURRENT_SPEND"
  }
  threshold_rules {
    threshold_percent = 1.0
    spend_basis       = "FORECASTED_SPEND"
  }

  all_updates_rule {
    monitoring_notification_channels = google_monitoring_notification_channel.budget[*].id
    disable_default_iam_recipients   = false
  }

  depends_on = [google_billing_project_info.this, google_project_service.free]
}
