# NO NAME LOOKUP OUT (ADR 22). Every VPC on Google Cloud resolves through the
# metadata server, 169.254.169.254, which answers any name on the internet
# whatever the routes say; a query carries whatever a workload puts in the
# name to whoever answers for that name. With no route out, DNS is the way
# out left, as it was on AWS (ADR 18).
#
# Two parts close it. Private zones answer the names the nodes need, Google's
# API and registry names, with restricted.googleapis.com's addresses, from
# inside the VPC. And a response policy on the network answers every other
# name with a name that does not exist (refused.boundary.internal), so no
# query for it leaves Cloud DNS. The policy lets through, unchanged, only the
# names the private zones answer and the VPC's own internal names
# (metadata.google.internal, the nodes'), which Google's own servers answer
# and no outside party reads.
#
# A wildcard rule stops at any name another rule names: "*." covers
# example.net, but not example.com once a rule names googleapis.com. Each
# top-level domain above an allowed name gets its own refusal for that reason.

locals {
  google_zones = {
    googleapis = "googleapis.com."
    gcr        = "gcr.io."
    pkg        = "pkg.dev."
  }
  refused = {
    all = "*."
    com = "*.com."
    io  = "*.io."
    dev = "*.dev."
  }
  allowed = merge(
    { for k, d in local.google_zones : k => d },
    { for k, d in local.google_zones : "${k}-names" => "*.${d}" },
    { internal = "internal.", internal-names = "*.internal." },
  )
}

resource "google_dns_managed_zone" "google" {
  for_each    = local.google_zones
  name        = "${var.cluster_name}-${each.key}"
  dns_name    = each.value
  description = "${each.value} answered with restricted.googleapis.com's addresses, inside the network (ADR 22)."
  visibility  = "private"

  private_visibility_config {
    networks {
      network_url = google_compute_network.this.id
    }
  }
}

resource "google_dns_record_set" "google" {
  for_each     = local.google_zones
  managed_zone = google_dns_managed_zone.google[each.key].name
  name         = each.value
  type         = "A"
  ttl          = 300
  rrdatas      = local.google_api_addresses
}

resource "google_dns_record_set" "google_names" {
  for_each     = local.google_zones
  managed_zone = google_dns_managed_zone.google[each.key].name
  name         = "*.${each.value}"
  type         = "CNAME"
  ttl          = 300
  rrdatas      = [each.value]
}

# On the network only when dns_firewall is true: the one run that shows the
# DNS check its violation leaves it off (ADR 22).
resource "google_dns_response_policy" "this" {
  response_policy_name = var.cluster_name
  description          = "Every name outside Google's APIs and the VPC's own is refused (ADR 22)."

  dynamic "networks" {
    for_each = var.dns_firewall ? [google_compute_network.this.id] : []
    content {
      network_url = networks.value
    }
  }
}

resource "google_dns_response_policy_rule" "refuse" {
  for_each        = local.refused
  response_policy = google_dns_response_policy.this.response_policy_name
  rule_name       = "refuse-${each.key}"
  dns_name        = each.value

  local_data {
    local_datas {
      name    = each.value
      type    = "CNAME"
      ttl     = 300
      rrdatas = ["refused.boundary.internal."]
    }
  }
}

resource "google_dns_response_policy_rule" "allow" {
  provider        = google-beta
  for_each        = local.allowed
  response_policy = google_dns_response_policy.this.response_policy_name
  rule_name       = "allow-${each.key}"
  dns_name        = each.value
  behavior        = "bypassResponsePolicy"
}
