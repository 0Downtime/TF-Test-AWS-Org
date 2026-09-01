# Azure DevOps pipeline replication

This repository contains the staged Terraform pipeline in
[`azure-pipelines.yml`](../azure-pipelines.yml) and a bootstrap helper at
[`scripts/azuredevops/setup-pipeline.sh`](../scripts/azuredevops/setup-pipeline.sh).

The helper is intentionally dry-run by default. It can generate the AWS OIDC
trust policy, AWS OIDC provider request, AWS Toolkit service-connection JSON,
and a checklist. External changes require an explicit `apply-aws`,
`apply-azure`, or `apply-all` mode.

## What can be automated

The helper can:

- Generate the exact OIDC subject for one AWS Toolkit service connection.
- Create or update the AWS OIDC provider and deployment role after you provide
  a separately reviewed permissions policy.
- Create the AWS service connection using Azure DevOps CLI configuration.
- Create the YAML pipeline from the repository's GitHub or Azure Repos source.
- Create the three mandatory deployment environments.
- Optionally upload the six mandatory secure files without opening them to all
  pipelines.
- Verify local JSON, shell, and Terraform formatting checks.

Environment approvals, branch-control checks, secure-file authorization, and
the permissions policy remain explicit setup boundaries. The script does not
silently grant `AdministratorAccess`, open secure files to every pipeline, or
weaken an existing service connection.

## One-time setup

1. Bootstrap stage 00 and verify the remote state bucket.
2. Install the AWS Toolkit for Azure DevOps and the Azure DevOps Azure CLI
   extension.
3. Authenticate Azure CLI and Azure DevOps. If your organization uses PAT
   authentication for Azure DevOps CLI, export `AZURE_DEVOPS_EXT_PAT` only in
   the current shell; do not put it in the local environment file.
4. Copy the example configuration and fill in the organization, project,
   account, role, and repository identifiers:

```bash
cp scripts/azuredevops/azure-devops-pipeline.example.env \
  scripts/azuredevops/azure-devops-pipeline.local.env
chmod 600 scripts/azuredevops/azure-devops-pipeline.local.env
```

5. Generate and review the artifacts:

```bash
bash scripts/azuredevops/setup-pipeline.sh plan \
  --config scripts/azuredevops/azure-devops-pipeline.local.env
```

After replacing the placeholders, run the read-only identity preflight before
any apply:

```bash
bash scripts/azuredevops/setup-pipeline.sh preflight \
  --config scripts/azuredevops/azure-devops-pipeline.local.env
```

The generated files are under `.azuredevops-bootstrap/` and are ignored by
Git. The role trust must contain these exact claims:

```text
aud = api://AzureADTokenExchange
sub = sc://<organization-name>/<project-name>/aws-terraform-oidc
```

6. Copy
[`aws-terraform-deployment-policy.example.json`](../scripts/azuredevops/aws-terraform-deployment-policy.example.json)
to a local policy file, replace every `REPLACE_*` value, and review it against
the actual stage plans. Set `AWS_PERMISSIONS_POLICY_FILE` to that local path.
The policy covers the mandatory stages, S3 state access, and only the required
`sts:AssumeRole` targets. Add stage-05 CloudFront/IAM permissions only when
stage 05 is deliberately enabled. The script rejects unresolved placeholders
or invalid JSON before changing IAM.

7. After reviewing the generated trust and permissions files, apply the AWS
side:

```bash
bash scripts/azuredevops/setup-pipeline.sh apply-aws \
  --config scripts/azuredevops/azure-devops-pipeline.local.env
```

The script verifies that `AWS_PROFILE` is authenticated to
`AWS_MANAGEMENT_ACCOUNT_ID` before it changes IAM. It creates or updates only
the named OIDC provider and named deployment role, then writes the supplied
inline policy.

8. Apply the Azure DevOps side:

```bash
bash scripts/azuredevops/setup-pipeline.sh apply-azure \
  --config scripts/azuredevops/azure-devops-pipeline.local.env
```

For this checkout, the repository source is GitHub. The GitHub service
connection required by Azure DevOps must already exist if the repository is
private. The command creates the AWS Toolkit service connection and the YAML
pipeline. It skips creation if either already exists.

The command creates the three environments if they do not already exist. It
does not configure approvals or checks, because those are security controls
owned by the Azure DevOps environment administrators.

9. Upload the secure files. Either use **Pipelines → Library → Secure files**,
or set `AZDO_SECURE_FILES_DIR` to a directory containing the six required files
and run:

```bash
export AZURE_DEVOPS_EXT_PAT='use-a-short-lived-token-in-this-shell-only'
bash scripts/azuredevops/setup-pipeline.sh upload-secure-files \
  --config scripts/azuredevops/azure-devops-pipeline.local.env
unset AZURE_DEVOPS_EXT_PAT
```

The upload mode does not authorize all pipelines. Explicitly authorize this
pipeline on each secure file afterward. Azure DevOps secure-file uploads are a
binary REST operation; the documented endpoint is described
[here](https://learn.microsoft.com/en-us/rest/api/azure/devops/distributedtask/securefiles/upload-secure-file?view=azure-devops-rest-7.2).

10. Create and protect these environments:

```text
aws-organization
aws-governance
aws-production
```

Add manual approvals, branch control for `refs/heads/main`, and an exclusive
lock where concurrent applies are not acceptable. The deployment jobs already
reference these exact names.

Authorize the named pipeline on the six required secure files listed in the
generated checklist. Add the stage-04 and stage-05 files only when enabling
those optional paths. Do not commit or publish the files.

## Normal operating flow

- Pull requests to `main` run formatting, validation, and plans only.
- A successful merge to `main` plans and applies stages 01, 02, and 03 in
  sequence.
- Each apply pauses at its protected environment and applies only the saved
  plan created from the same source commit.
- Queue-time parameters `enable_entra_access` and `enable_gitlab_oidc` remain
  false unless their separate prerequisites are complete.

For an existing AWS Organization, import the organization, OUs, and accounts
before the first pipeline apply; otherwise stage 01 may attempt to create
resources that already exist. IAM Identity Center must be enabled before stage
02, and `OrganizationAccountAccessRole` must be usable in the member accounts.

## Verification

Run before committing the setup changes:

```bash
bash scripts/azuredevops/setup-pipeline.sh verify \
  --config scripts/azuredevops/azure-devops-pipeline.local.env
```

The pipeline's own validation job also runs Terraform formatting and validates
stages 01–05 without contacting AWS.
