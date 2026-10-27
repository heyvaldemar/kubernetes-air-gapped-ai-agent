variable "project" {
  description = "The validation project, under the maintainer's organization, that holds nothing but these runs."
  type        = string
  default     = "valdemar-platform-validation"
}

variable "region" {
  description = "The one region every run uses."
  type        = string
  default     = "us-central1"
}

variable "billing_account" {
  description = <<-EOT
    The billing account to link, as its ID. Null until the maintainer has made
    one: the federation and the service accounts cost nothing and are applied
    without it; the billed APIs, the state bucket and the budget wait for it.
  EOT
  type        = string
  default     = null
}

variable "alert_email" {
  description = "Where the budget's alerts go besides the billing account's administrators. Given at apply, never written here."
  type        = string
  default     = null

  validation {
    condition     = var.alert_email == null || can(regex("^[^@[:space:]]+@[^@[:space:]]+$", var.alert_email))
    error_message = "alert_email is one address."
  }
}

variable "budget_amount" {
  description = "The month's budget for the project, in the billing account's currency, before any credit."
  type        = number
  default     = 10
}
