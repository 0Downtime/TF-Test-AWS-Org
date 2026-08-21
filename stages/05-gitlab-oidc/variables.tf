variable "management_account_id" {
  description = "AWS Organizations management account ID."
  type        = string
}

variable "management_profile" {
  description = "Optional AWS CLI profile for the management account."
  type        = string
  default     = ""
}

variable "management_region" {
  description = "Region for the metadata bucket and CloudFront origin."
  type        = string
  default     = "us-east-1"
}

variable "production_account_id" {
  description = "Production account ID that will contain the GitLab OIDC provider and role."
  type        = string
}

variable "production_region" {
  description = "Region for the production-account IAM resources."
  type        = string
  default     = "us-east-1"
}

variable "oidc_bucket_name" {
  description = "Globally unique private S3 bucket name for the GitLab OIDC mirror."
  type        = string
}

variable "create_aws_oidc_resources" {
  description = "Create the production-account IAM OIDC provider and GitLab role after the public mirror has been populated and GitLab has been configured."
  type        = bool
  default     = false
}

variable "gitlab_oidc_audience" {
  description = "Audience configured in the GitLab CI ID token and registered with AWS IAM."
  type        = string
  default     = "sts.amazonaws.com"
}

variable "gitlab_subject" {
  description = "Exact GitLab ID-token subject allowed to assume the role. Pin this to a protected project branch."
  type        = string
  default     = ""

  validation {
    condition     = !var.create_aws_oidc_resources || length(var.gitlab_subject) > 0
    error_message = "gitlab_subject must be set when create_aws_oidc_resources is true."
  }
}

variable "gitlab_role_name" {
  description = "Name of the production-account role assumed by the GitLab job."
  type        = string
  default     = "GitLabProductionDeploy"
}

variable "gitlab_role_policy_json" {
  description = "Optional least-privilege inline policy for the GitLab role. Leave null until the deployment permissions are known."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition     = var.gitlab_role_policy_json == null || can(jsondecode(var.gitlab_role_policy_json))
    error_message = "gitlab_role_policy_json must contain valid JSON when supplied."
  }
}
