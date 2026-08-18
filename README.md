# AWS Organization baseline

This repository is a staged deployment for the architecture in the reference diagram:

- management account with AWS Organizations and trusted service access
- Security, Infrastructure, and Workloads organizational units
- log-archive account under Security
- production account under Workloads
- organization-wide CloudTrail delivered to the log-archive account
- IAM Identity Center permission sets with optional group assignments
- an empty, protected Secrets Manager secret in the production account

The stages are intentional. Account creation and cross-account role assumption are separate operations in AWS, so child-account resources are not placed in the same Terraform state as account creation.

## Before deployment

1. Decide whether the management account already owns an AWS Organization. For an existing organization, import and review the organization resource rather than creating a second organization.
2. Create an encrypted, versioned remote Terraform state bucket outside these stacks. Configure an S3 backend per stage using `-backend-config`; the backend cannot be created by the state that depends on it.
3. Prepare two unique, valid root-email addresses for the member accounts.
4. Enable an organization instance of IAM Identity Center in the region you will use for SSO. Create an administrative group and record its identity-store group ID if you want Terraform to assign access.

## Deployment

Run each stage from its own directory and state. Use the same management-account profile for all stages; the cross-account providers use that profile as their source credentials.

```bash
cd stages/01-organization
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with real unique account emails.
terraform init -backend-config=backend.hcl
terraform plan
terraform apply
terraform output
```

Create `backend.hcl` in each stage by copying its `backend.hcl.example` and setting the actual state bucket name. The state bucket must already exist, have versioning enabled, and be restricted to the Terraform operators.

Wait for both member accounts to finish provisioning and verify that `OrganizationAccountAccessRole` can be assumed. Then configure the account IDs in the next stage:

```bash
cd ../02-governance
cp terraform.tfvars.example terraform.tfvars
# Set organization_id, management_account_id, and log_archive_account_id.
terraform init -backend-config=backend.hcl
terraform plan
terraform apply
```

Finally deploy the production-account baseline:

```bash
cd ../03-production
cp terraform.tfvars.example terraform.tfvars
# Set production_account_id.
terraform init -backend-config=backend.hcl
terraform plan
terraform apply
```

Do not commit `terraform.tfvars` or backend credentials. Review every plan, especially changes to the organization, account parents, CloudTrail bucket policy, IAM Identity Center assignments, and the protected log bucket.

## Validation

```bash
terraform fmt -check -recursive
terraform -chdir=stages/01-organization init -backend=false
terraform -chdir=stages/01-organization validate
terraform -chdir=stages/02-governance init -backend=false
terraform -chdir=stages/02-governance validate
terraform -chdir=stages/03-production init -backend=false
terraform -chdir=stages/03-production validate
```
