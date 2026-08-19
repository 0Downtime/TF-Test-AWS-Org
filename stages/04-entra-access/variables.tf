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
  description = "Configurable prefix for the Entra access group name."
  type        = string
  default     = "SRA-PROD"
}

variable "group_name_suffix" {
  description = "Suffix for the Entra access group name."
  type        = string
  default     = "SecretsManagerAdminReadOnly"
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

variable "owner_object_ids" {
  description = "Optional Entra user or service-principal object IDs to own the group. The authenticated Terraform identity remains the default owner when empty."
  type        = set(string)
  default     = []
}
