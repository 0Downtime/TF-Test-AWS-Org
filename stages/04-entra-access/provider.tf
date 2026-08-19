provider "azuread" {
  tenant_id = var.tenant_id
  use_cli   = var.use_azure_cli
}

data "azuread_client_config" "current" {}
