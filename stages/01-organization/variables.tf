variable "management_account_id" {
  description = "The AWS account ID that will manage the organization."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.management_account_id))
    error_message = "management_account_id must be a 12-digit AWS account ID."
  }
}

variable "management_profile" {
  description = "Optional AWS CLI profile for the management account."
  type        = string
  default     = ""
}

variable "management_region" {
  description = "AWS provider region for the management account."
  type        = string
  default     = "us-east-1"
}

variable "organization_name" {
  description = "Human-readable name used in account tags."
  type        = string
  default     = "production-organization"
}

variable "log_archive_account_email" {
  description = "Unique, valid root email address for the log archive account."
  type        = string

  validation {
    condition     = can(regex("^[^@[:space:]]+@[^@[:space:]]+\\.[^@[:space:]]+$", var.log_archive_account_email))
    error_message = "Provide a valid email address for the log archive account."
  }
}

variable "production_account_email" {
  description = "Unique, valid root email address for the production account."
  type        = string

  validation {
    condition     = can(regex("^[^@[:space:]]+@[^@[:space:]]+\\.[^@[:space:]]+$", var.production_account_email))
    error_message = "Provide a valid email address for the production account."
  }
}
