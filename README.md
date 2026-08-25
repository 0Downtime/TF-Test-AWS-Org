# AWS Organization baseline

Terraform and PowerShell automation for a staged AWS Organization foundation, AWS IAM Identity Center governance, an optional production Secrets Manager baseline, and Entra ID federation.

The supported workflow uses the directories under `stages/`. Each stage has its own Terraform state so account creation, cross-account resources, Azure resources, and federation changes remain independently reviewable.

## What this repository manages

| Stage | Purpose | Credentials used |
| --- | --- | --- |
| `00-state-bucket` | Creates the encrypted, versioned, private S3 bucket used by later Terraform backends. | AWS management account |
| `01-organization` | Creates or adopts the AWS Organization, OUs, and configurable member accounts. | AWS management account |
| `02-governance` | Creates the log-archive bucket, organization CloudTrail, IAM Identity Center permission sets, and optional group assignments. | Management account plus `OrganizationAccountAccessRole` in the log-archive account |
| `03-production` | Creates an empty, protected Secrets Manager secret and an optional least-privilege access role in the production account. | Management account plus `OrganizationAccountAccessRole` in the production account |
| `04-entra-access` | Creates the non-mail-enabled Entra security groups used by the Secrets Manager and production administrator mappings. | Current Azure CLI login |
| `05-gitlab-oidc` | Hosts the two public OIDC metadata objects for a private GitLab instance and optionally creates the AWS IAM OIDC provider and narrowly trusted workload role. | AWS management account plus a trusted private GitLab metadata-sync runner |

The federation scripts configure Entra SAML, SCIM provisioning, managed AWS CLI SSO profiles, and generated Terraform assignment inputs. The first IAM Identity Center identity-source cutover and SCIM setup still require an AWS/Entra console workflow; see the [production federation runbook](docs/entra-aws-federation-production-runbook.md).

The private GitLab OIDC mirror, synchronization script, two-phase bootstrap, and protected-ref acceptance checks are documented in the [private GitLab OIDC runbook](docs/gitlab-private-oidc-runbook.md).

The root-level Terraform files are the original monolithic configuration and are not part of the supported staged workflow. Run Terraform from a stage directory, not from the repository root. The staged configuration is the maintained path for new deployments and existing-environment adoption.

## Prerequisites

- Terraform `>= 1.5.0, < 2.0.0`.
- AWS CLI v2 and credentials for the management account. Use a named profile where possible.
- An AWS Organization or permission to create one. The management account must be able to use Organizations, IAM Identity Center, CloudTrail, S3, and cross-account role assumption as applicable.
- An organization instance of IAM Identity Center enabled in the region configured for stage 02.
- Two unique member-account root email addresses when stage 01 will create accounts.
- PowerShell 7, Microsoft Graph PowerShell, and Pester for the Windows federation workflow.
- Azure CLI logged in to the target tenant if stage 04 is used with its default `use_azure_cli = true`.

Do not commit `terraform.tfvars`, `backend.hcl`, local federation/adoption JSON, generated plan files, metadata XML, SCIM tokens, private keys, or DPAPI-protected files. Terraform state can contain sensitive infrastructure metadata; protect the state bucket and its access accordingly.

The repository ignores host-local `*.tfvars`, `*.tfvars.json`, `*.hcl`, and `*.tfplan` files while keeping `*.hcl.example` templates and `.terraform.lock.hcl` files tracked. For the strongest protection when changing branches or working on multiple clones, keep the real variable and backend files outside the Git working tree and pass their paths with `-var-file` and `-backend-config`.

## Deployment order

```text
00 state bucket
      |
01 organization and accounts
      |
wait for member accounts and OrganizationAccountAccessRole
      |
02 governance and IAM Identity Center
      |
03 production baseline
      |
04 optional Entra group -> manual SAML/SCIM -> federation automation
      |
05 optional private GitLab OIDC metadata mirror -> IAM provider -> reviewed workload role
```

The Entra and federation path is optional. If group assignments are enabled, complete stage 02 permission-set setup first, then provision the Entra group and rerun the governance plan after the federation script generates the SCIM group ID mapping.

## Quick start

The commands below assume Bash from the repository root. In PowerShell, use `Copy-Item` in place of `cp` and run each Terraform command from the indicated stage directory if `-chdir` path handling differs in your installed Terraform version.

### 1. Create the state bucket

```bash
cp stages/00-state-bucket/terraform.tfvars.example stages/00-state-bucket/terraform.tfvars
# Edit the management account ID, profile, region, and globally unique bucket name.
terraform -chdir=stages/00-state-bucket init
terraform -chdir=stages/00-state-bucket plan -out=tfplan
terraform -chdir=stages/00-state-bucket apply tfplan
terraform -chdir=stages/00-state-bucket output
```

Stage 00 intentionally uses local state because it creates the remote backend used by later stages. Its bucket has versioning, server-side encryption, public-access blocking, and `prevent_destroy` protection.

### 2. Create or adopt the organization

For a new organization:

```bash
cp stages/01-organization/terraform.tfvars.example stages/01-organization/terraform.tfvars
cp stages/01-organization/backend.hcl.example stages/01-organization/backend.hcl
# Set the state bucket, management account, and unique member-account emails.
terraform -chdir=stages/01-organization init -backend-config=backend.hcl
terraform -chdir=stages/01-organization plan -out=tfplan
terraform -chdir=stages/01-organization apply tfplan
terraform -chdir=stages/01-organization output
```

For an existing organization, set `create_member_accounts = false`, leave the legacy account-email variables empty when `member_accounts` is not being used, and import the organization before planning:

```powershell
terraform -chdir=stages/01-organization import `
  -var="management_account_id=000000000000" `
  -var="management_profile=management" `
  -var="management_region=us-east-1" `
  -var="create_member_accounts=false" `
  aws_organizations_organization.this o-example1234
```

Configure `organizational_units` and `member_accounts` to match the enterprise naming and account map. Existing resources must be imported before Terraform can converge them. The adoption helper is documented below.

Wait for newly created accounts to become `ACTIVE` and verify that `OrganizationAccountAccessRole` can be assumed before continuing.

### 3. Apply governance

```bash
cp stages/02-governance/terraform.tfvars.example stages/02-governance/terraform.tfvars
cp stages/02-governance/backend.hcl.example stages/02-governance/backend.hcl
# Set organization_id, management_account_id, log_archive_account_id, and bucket name.
terraform -chdir=stages/02-governance init -backend-config=backend.hcl
terraform -chdir=stages/02-governance plan -out=tfplan
terraform -chdir=stages/02-governance apply tfplan
terraform -chdir=stages/02-governance output
```

Before applying, enable IAM Identity Center in the intended `identity_center_region`. Review the CloudTrail destination policy, account IDs, permission-set policies, and any configured group assignments. The `SecretsManagerAdminReadOnly` permission set combines AWS `ReadOnlyAccess` with an inline `secretsmanager:*` allow. The separate `SecretsManagerReadWrite` permission set grants only core Secrets Manager list/read/create/update/delete/restore/tag operations and is the preferred routine path when those actions are sufficient. `AdministratorAccess` is full account administration; all three require explicit approval.

### 4. Apply the production baseline

```bash
cp stages/03-production/terraform.tfvars.example stages/03-production/terraform.tfvars
cp stages/03-production/backend.hcl.example stages/03-production/backend.hcl
# Set production_account_id, profile, region, and secret name.
terraform -chdir=stages/03-production init -backend-config=backend.hcl
terraform -chdir=stages/03-production plan -out=tfplan
terraform -chdir=stages/03-production apply tfplan
terraform -chdir=stages/03-production output
```

Stage 03 creates a secret container but never stores a secret value. The optional `production_trusted_principal_arns` input creates a role with the `SecretsManagerRead` policy attached, plus separate `SecretsManagerRead` and `SecretsManagerReadWrite` policy ARNs. Attach the read/write policy only to an explicitly approved principal that needs to update the baseline secret; leave the input empty until a real workload or administration principal exists.

### 5. Optional Entra access and federation

Create the Entra group after `az login` to the target tenant:

```powershell
az login --tenant <entra-tenant-id>
Copy-Item .\stages\04-entra-access\terraform.tfvars.example .\stages\04-entra-access\terraform.tfvars
Copy-Item .\stages\04-entra-access\backend.hcl.example .\stages\04-entra-access\backend.hcl
# Set tenant_id and the state bucket in the ignored files.
Push-Location .\stages\04-entra-access
terraform init -reconfigure -backend-config backend.hcl
terraform validate
terraform plan -out=entra-access.tfplan
terraform apply entra-access.tfplan
Pop-Location
```

The groups are security-enabled, non-mail-enabled, and protected against Terraform destruction. Membership and SCIM provisioning remain separate operations. The administrator group is `AWS-Production-Administrators`; add only approved production administrators through your existing company access-control process. This repository does not configure PIM. If the existing Secrets Manager group already exists, import it before planning:

```powershell
terraform -chdir=stages/04-entra-access import azuread_group.secrets_manager_admin_read_only /groups/<entra-group-object-id>
```

If the production administrator group already exists, import it separately:

```powershell
terraform -chdir=stages/04-entra-access import azuread_group.production_administrators /groups/<administrator-group-object-id>
```

For the complete SAML, SCIM, certificate, quota, managed-profile, and governance workflow, follow the [Entra ID federation production runbook](docs/entra-aws-federation-production-runbook.md). The canonical entry point is:

```powershell
pwsh .\scripts\Invoke-AwsEntraFederationBootstrap.ps1 `
  -Mode Validate `
  -OrganizationMode Skip `
  -ConfigPath .\scripts\entra-aws-federation.local.json
```

Start from the example configuration, keep the local copy ignored, and supply SCIM credentials only through the secure prompt or a local secure parameter. `Apply` requires explicit approval for the identity-source boundary; organization creation, quota requests, and governance apply have separate approvals. When `-ApplyGovernance` is used, the federation phase writes the generated assignment variables, creates `federation-governance.tfplan`, and applies that exact saved plan rather than running an unplanned `terraform apply -auto-approve`. Omit `-ApplyGovernance` when a separate human review is required between planning and applying governance.

## Existing-environment adoption and account quota

The organization stage is configuration-driven. To generate a read-only adoption plan from Windows, copy the example outside source control or to an ignored local path:

```powershell
pwsh .\scripts\Adopt-AwsTerraformResources.ps1 `
  -ConfigPath .\scripts\aws-terraform-adoption.local.json `
  -Mode Plan
```

Review the proposed resource addresses and redacted identifiers. Run `-Mode Apply -Approve` only after review; it imports existing resources into Terraform state but does not modify AWS resources. Run Terraform plan afterward and review any convergence changes before applying them.

Before creating member accounts, run the quota preflight:

```powershell
pwsh .\scripts\Ensure-AwsOrganizationsAccountQuota.ps1 `
  -ManagementProfile management `
  -Region us-east-1 `
  -RequiredAccountCount 3 `
  -Mode Plan `
  -RequireReady
```

If no request is open and AWS requires an increase, submit one separately with `-Mode Request -Approve`. Do not submit another request while the result is `Pending`, `CASE_OPENED`, or otherwise indicates that an existing request is active.

For normal organization bootstrapping, the gated wrapper combines the quota preflight with Terraform plan/apply:

```powershell
pwsh .\scripts\Invoke-AwsOrganizationBootstrap.ps1 `
  -ManagementProfile management `
  -Region us-east-1 `
  -RequiredAccountCount 3 `
  -Mode Plan

pwsh .\scripts\Invoke-AwsOrganizationBootstrap.ps1 `
  -ManagementProfile management `
  -Region us-east-1 `
  -RequiredAccountCount 3 `
  -Mode Apply
```

The federation orchestrator is the preferred production entry point when organization bootstrap, federation, and optional governance handoff need to be coordinated.

## Windows OpenSSH helper

When Windows Features-on-Demand cannot install OpenSSH on the target VM, `scripts/Install-WindowsOpenSSHFromGitHub.ps1` installs the repository's pinned official Microsoft Win32-OpenSSH release and verifies its SHA-256 hash. Run it from an elevated PowerShell session with an SSH public key. It does not create or store a private key. The older `Enable-WindowsOpenSSHForCodex.ps1` remains available for systems where the built-in Windows capability works.

## Validation

Run formatting and Terraform validation from the repository root:

```bash
terraform fmt -check -recursive

for stage in 00-state-bucket 01-organization 02-governance 03-production 04-entra-access; do
  terraform -chdir="stages/$stage" init -backend=false
  terraform -chdir="stages/$stage" validate
done
```

On Windows, run the PowerShell tests after installing Pester:

```powershell
Invoke-Pester -Path .\tests\Configure-AwsEntraFederation.Tests.ps1 -Output Detailed
```

Validation proves syntax and static safety only. It does not prove AWS account access, quota readiness, SAML/SCIM health, physical account provisioning, or a successful end-to-end SSO login. Use the runbook's acceptance checklist for those checks.

## Repository layout

```text
stages/00-state-bucket/       Remote-state bootstrap
stages/01-organization/       Organization, OUs, and member accounts
stages/02-governance/         CloudTrail, log archive, permission sets
stages/03-production/         Production secret baseline
stages/04-entra-access/       Entra security group
stages/05-gitlab-oidc/        Private GitLab OIDC metadata mirror and AWS trust
scripts/                      Adoption, quota, federation, OIDC sync/test, and OpenSSH tools
scripts/lib/                  Shared PowerShell and Terraform handoff modules
docs/                         Production federation runbook
tests/                        Pester static-safety tests
```

Review every plan. In particular, treat organization/account creation, identity-source changes, permission-set assignments, quota requests, IAM policy changes, CloudTrail bucket policies, and secret-access roles as explicit approval boundaries.
