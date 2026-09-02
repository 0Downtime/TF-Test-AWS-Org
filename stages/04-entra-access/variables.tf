variable "tenant_id" {
  description = "Microsoft Entra tenant ID."
  type        = string
}

variable "use_azure_cli" {
  description = "Use the current Azure CLI login for local Terraform authentication."
  type        = bool
  default     = true
}

variable "group_name_prefix" {
  description = "Environment-specific prefix for Terraform-managed Entra access groups. Supply this in the ignored environment tfvars file."
  type        = string

  validation {
    condition     = trimspace(var.group_name_prefix) != ""
    error_message = "group_name_prefix must be supplied in the environment configuration."
  }
}

variable "group_name_suffix" {
  description = "Purpose suffix for the Secrets Manager access group. Supply this in the ignored environment tfvars file."
  type        = string

  validation {
    condition     = trimspace(var.group_name_suffix) != ""
    error_message = "group_name_suffix must be supplied in the environment configuration."
  }
}

variable "group_display_name" {
  description = "Optional explicit display name override. Leave empty to use group_name_prefix-group_name_suffix."
  type        = string
  default     = ""
}

variable "group_mail_nickname" {
  description = "Optional explicit mail nickname override. Leave empty to derive one from the display name."
  type        = string
  default     = ""
}

variable "group_description" {
  description = "Description shown for the Entra security group."
  type        = string
  default     = "AWS IAM Identity Center access: full Secrets Manager and read-only access to other AWS resources."
}

variable "administrator_group_display_name" {
  description = "Display name for the administrator Entra security group. Supply this in the ignored environment tfvars file."
  type        = string

  validation {
    condition     = trimspace(var.administrator_group_display_name) != ""
    error_message = "administrator_group_display_name must be supplied in the environment configuration."
  }
}

variable "administrator_group_mail_nickname" {
  description = "Mail nickname for the administrator Entra security group. Supply this in the ignored environment tfvars file."
  type        = string

  validation {
    condition     = trimspace(var.administrator_group_mail_nickname) != ""
    error_message = "administrator_group_mail_nickname must be supplied in the environment configuration."
  }
}

variable "administrator_group_description" {
  description = "Description shown for the production administrator Entra security group."
  type        = string
  default     = "AWS IAM Identity Center AdministratorAccess for explicitly approved production administrators."
}

variable "owner_object_ids" {
  description = "Optional Entra user or service-principal object IDs to own the group. The authenticated Terraform identity remains the default owner when empty."
  type        = set(string)
  default     = []
}
