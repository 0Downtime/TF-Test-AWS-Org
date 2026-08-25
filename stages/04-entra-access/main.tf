locals {
  group_display_name  = trimspace(var.group_display_name) != "" ? var.group_display_name : "${var.group_name_prefix}-${var.group_name_suffix}"
  group_mail_nickname = trimspace(var.group_mail_nickname) != "" ? var.group_mail_nickname : lower("${var.group_name_prefix}-${var.group_name_suffix}")
}

resource "azuread_group" "secrets_manager_admin_read_only" {
  display_name            = local.group_display_name
  description             = var.group_description
  security_enabled        = true
  mail_enabled            = false
  mail_nickname           = local.group_mail_nickname
  owners                  = var.owner_object_ids
  prevent_duplicate_names = true

  lifecycle {
    prevent_destroy = true
  }
}

resource "azuread_group" "production_administrators" {
  display_name            = var.administrator_group_display_name
  description             = var.administrator_group_description
  security_enabled        = true
  mail_enabled            = false
  mail_nickname           = var.administrator_group_mail_nickname
  owners                  = var.owner_object_ids
  prevent_duplicate_names = true

  lifecycle {
    prevent_destroy = true
  }
}

check "group_is_security_enabled" {
  assert {
    condition     = azuread_group.secrets_manager_admin_read_only.security_enabled && !azuread_group.secrets_manager_admin_read_only.mail_enabled
    error_message = "The AWS access group must be a non-mail-enabled Entra security group for SCIM provisioning."
  }
}

check "administrator_group_is_security_enabled" {
  assert {
    condition     = azuread_group.production_administrators.security_enabled && !azuread_group.production_administrators.mail_enabled
    error_message = "The production administrator group must be a non-mail-enabled Entra security group for SCIM provisioning."
  }
}
