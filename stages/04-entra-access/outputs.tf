output "group_object_id" {
  description = "Entra object ID of the AWS access group. SCIM will provision a separate IAM Identity Center group ID."
  value       = azuread_group.secrets_manager_admin_read_only.object_id
}

output "group_display_name" {
  description = "Display name used to resolve the group in the federation configuration."
  value       = local.group_display_name
}

output "administrator_group_object_id" {
  description = "Entra object ID of the production administrator group. SCIM will provision a separate IAM Identity Center group ID."
  value       = azuread_group.production_administrators.object_id
}

output "administrator_group_display_name" {
  description = "Display name of the production administrator group."
  value       = azuread_group.production_administrators.display_name
}
