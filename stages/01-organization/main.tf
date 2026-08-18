resource "aws_organizations_organization" "this" {
  feature_set = "ALL"

  enabled_policy_types = [
    "SERVICE_CONTROL_POLICY",
  ]

  aws_service_access_principals = [
    "cloudtrail.amazonaws.com",
    "sso.amazonaws.com",
  ]
}

locals {
  ous = {
    security       = "Security"
    infrastructure = "Infrastructure"
    workloads      = "Workloads"
  }

  accounts = {
    log_archive = {
      name  = "log-archive"
      email = var.log_archive_account_email
      ou    = "security"
    }
    production = {
      name  = "production"
      email = var.production_account_email
      ou    = "workloads"
    }
  }
}

resource "aws_organizations_organizational_unit" "this" {
  for_each  = local.ous
  name      = each.value
  parent_id = aws_organizations_organization.this.roots[0].id
}

resource "aws_organizations_account" "this" {
  for_each = local.accounts

  name                       = each.value.name
  email                      = each.value.email
  role_name                  = "OrganizationAccountAccessRole"
  parent_id                  = aws_organizations_organizational_unit.this[each.value.ou].id
  close_on_deletion          = false
  iam_user_access_to_billing = "DENY"

  tags = {
    AccountType  = each.key
    ManagedBy    = "Terraform"
    Organization = var.organization_name
  }

  depends_on = [aws_organizations_organization.this]
}
