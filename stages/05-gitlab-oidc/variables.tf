variable "management_account_id" {
  description = "AWS account ID that owns the OIDC metadata bucket and IAM resources."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.management_account_id))
    error_message = "management_account_id must be a 12-digit AWS account ID."
  }
}

variable "aws_profile" {
  description = "Optional named AWS CLI profile for the management account."
  type        = string
  default     = ""
}

variable "aws_region" {
  description = "AWS region for the metadata bucket and IAM resources."
  type        = string
  default     = "us-east-1"
}

variable "metadata_bucket_name" {
  description = "Globally unique private S3 bucket containing only the two public OIDC metadata objects."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.metadata_bucket_name))
    error_message = "metadata_bucket_name must be a valid S3 bucket name between 3 and 63 characters."
  }
}

variable "cloudfront_price_class" {
  description = "CloudFront price class for the two small metadata objects."
  type        = string
  default     = "PriceClass_100"

  validation {
    condition     = contains(["PriceClass_100", "PriceClass_200", "PriceClass_All"], var.cloudfront_price_class)
    error_message = "cloudfront_price_class must be PriceClass_100, PriceClass_200, or PriceClass_All."
  }
}

variable "metadata_cache_seconds" {
  description = "CloudFront cache lifetime for discovery and JWKS objects. Keep this short enough to accommodate key rotation."
  type        = number
  default     = 300

  validation {
    condition     = var.metadata_cache_seconds >= 60 && var.metadata_cache_seconds <= 3600
    error_message = "metadata_cache_seconds must be between 60 and 3600 seconds."
  }
}

variable "oidc_audience" {
  description = "Audience accepted by the IAM OIDC provider and emitted by GitLab CI jobs."
  type        = string
  default     = "sts.amazonaws.com"

  validation {
    condition     = length(trimspace(var.oidc_audience)) > 0
    error_message = "oidc_audience must not be empty."
  }
}

variable "oidc_thumbprints" {
  description = "Optional IAM OIDC provider certificate thumbprints. Leave empty unless your AWS provider version or certificate setup requires them."
  type        = list(string)
  default     = []
}

variable "enable_iam_oidc_provider" {
  description = "Create the AWS IAM OIDC provider. Set true only after the public metadata endpoints return valid GitLab documents."
  type        = bool
  default     = false
}

variable "create_gitlab_role" {
  description = "Create the IAM role that GitLab CI can assume with web identity."
  type        = bool
  default     = false
}

variable "gitlab_role_name" {
  description = "Name of the workload role assumed by GitLab CI."
  type        = string
  default     = "GitLabTerraform"
}

variable "allowed_subjects" {
  description = "Exact GitLab OIDC sub claims allowed to assume the workload role. Use one exact protected branch or tag subject per entry."
  type        = set(string)
  default     = []
}

variable "gitlab_role_policy_arns" {
  description = "Managed policy ARNs attached to the GitLab workload role. Keep this empty until the required Terraform permissions are reviewed."
  type        = set(string)
  default     = []
}

variable "create_metadata_sync_role" {
  description = "Create a role limited to reading and writing the two OIDC metadata objects."
  type        = bool
  default     = false
}

variable "metadata_sync_role_name" {
  description = "Name of the least-privilege metadata synchronization role."
  type        = string
  default     = "GitLabOidcMetadataSync"
}

variable "metadata_sync_principal_arns" {
  description = "AWS principal ARNs allowed to assume the metadata synchronization role, such as a trusted runner role."
  type        = set(string)
  default     = []
}
