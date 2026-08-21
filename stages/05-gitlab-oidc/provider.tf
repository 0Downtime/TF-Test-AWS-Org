provider "aws" {
  region  = var.management_region
  profile = var.management_profile != "" ? var.management_profile : null

  allowed_account_ids = [var.management_account_id]

  default_tags {
    tags = {
      ManagedBy = "Terraform"
      Stage     = "gitlab-oidc"
    }
  }
}

provider "aws" {
  alias   = "production"
  region  = var.production_region
  profile = var.management_profile != "" ? var.management_profile : null

  allowed_account_ids = [var.production_account_id]

  assume_role {
    role_arn     = "arn:aws:iam::${var.production_account_id}:role/OrganizationAccountAccessRole"
    session_name = "terraform-gitlab-oidc"
  }
}

data "aws_caller_identity" "management" {}

check "management_account" {
  assert {
    condition     = data.aws_caller_identity.management.account_id == var.management_account_id
    error_message = "The selected AWS credentials are not for management_account_id."
  }
}
