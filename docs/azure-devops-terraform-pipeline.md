# Azure DevOps Terraform pipeline

The repository includes [`azure-pipelines.yml`](../azure-pipelines.yml) for the
maintained staged workflow. It deploys stages 01–03 in order and includes
stages 04–05 as explicitly enabled, approval-gated paths. Stage 00 is not part
of the pipeline because it creates the remote state bucket used by the other
stages.

Every validation and deployment run first executes a security gate. The gate
uses pinned Gitleaks and Trivy container images to scan the repository for
committed secrets and the bootstrapped state bucket plus each enabled Terraform
stage for HIGH or CRITICAL misconfigurations. Either a secret finding or an IaC
finding blocks every plan and apply. SARIF reports are published as the
`security-scan-reports` pipeline artifact, including when the gate fails.

Run the same gate locally from a checkout with Docker available:

```bash
mkdir -p .security-scan
bash scripts/ci/security-scan.sh "$PWD" "$PWD/.security-scan" stages
```

Do not add blanket Trivy or Gitleaks ignores to make a run green. If a finding
is accepted after security review, record the narrowly scoped rationale and
expiry in the change that introduces the exception. The repository records the
customer-approved SSE-S3 choice with expiring inline exceptions for the
customer-managed-KMS checks; no customer-managed keys are created. The
CloudFront WAF finding remains a blocker when stage 05 is enabled and must be
remediated or explicitly approved before that deployment.

For reproducible setup of the AWS OIDC role, Azure DevOps service connection,
pipeline, environments, and secure-file upload, use the
[pipeline replication guide](azure-devops-pipeline-replication.md) and its
[`setup-pipeline.sh`](../scripts/azuredevops/setup-pipeline.sh) helper.

For a non-production stage-05 bootstrap or test, use
[`azure-pipelines-stage05-test.yml`](../azure-pipelines-stage05-test.yml). It
validates and plans only stage 05, so it does not require the secure files for
stages 01–04 and it has no apply job. Use the maintained staged workflow for
production changes.

## Azure DevOps prerequisites

Install or enable these Azure DevOps tasks/extensions in the project:

- AWS Toolkit for Azure DevOps, for `AWSShellScript@1` and the AWS OIDC service
  connection.
- Terraform task support, for `TerraformInstaller@1`.
- Azure Pipelines built-in tasks, including `AzureCLI@2`,
  `DownloadSecureFile@1`, and `PublishPipelineArtifact@1`.

Create these protected environments and add manual approvals, branch control,
and any required exclusive locks:

| Environment | Terraform stage | Approval boundary |
| --- | --- | --- |
| `aws-organization` | `01-organization` | Organization, OU, and account changes |
| `aws-governance` | `02-governance` | CloudTrail, IAM Identity Center, and IAM changes |
| `aws-production` | `03-production` | Production secret and access-role changes |
| `entra-access` | `04-entra-access` | Entra security-group changes |
| `gitlab-oidc` | `05-gitlab-oidc` | Public metadata and workload-trust changes |

Only the `main` branch should be allowed to consume these deployment
environments. Azure DevOps environments and other protected resources support
approvals, checks, and pipeline permissions:

- [Pipeline approvals and checks](https://learn.microsoft.com/en-us/azure/devops/pipelines/process/approvals?view=azure-devops)
- [Pipeline resource security](https://learn.microsoft.com/en-us/azure/devops/pipelines/security/resources?view=azure-devops)

## AWS OIDC service connection

Use an AWS Toolkit service connection named `aws-terraform-oidc`, or pass a
different name through the pipeline's `aws_service_connection` parameter.
Select **Use OIDC** when creating the connection. Do not configure long-lived
AWS access keys in the pipeline.

In the AWS management account, create or verify an IAM OIDC provider for the
Azure DevOps organization:

```text
https://vstoken.dev.azure.com/<organization-guid>
```

Create a dedicated Terraform deployment role whose trust policy is limited to
the exact service connection. The important conditions are:

```json
{
  "Effect": "Allow",
  "Principal": {
    "Federated": "arn:aws:iam::<management-account-id>:oidc-provider/vstoken.dev.azure.com/<organization-guid>"
  },
  "Action": "sts:AssumeRoleWithWebIdentity",
  "Condition": {
    "StringEquals": {
      "vstoken.dev.azure.com/<organization-guid>:aud": "api://AzureADTokenExchange",
      "vstoken.dev.azure.com/<organization-guid>:sub": "sc://<organization>/<project>/aws-terraform-oidc"
    }
  }
}
```

The role policy must be reviewed against the actual stages. It needs the
management-account APIs used by stages 01, 02, and 05, access to the S3 state
bucket, and `sts:AssumeRole` only for the member-account
`OrganizationAccountAccessRole` targets required by stages 02 and 03. Do not
grant unrelated account administration or wildcard cross-account role access.

The AWS Toolkit's shell task injects temporary credentials as standard AWS
environment variables for the Terraform command:

- [AWS Shell Script task](https://docs.aws.amazon.com/vsts/latest/userguide/awsshell.html)
- [AWS guidance for Azure DevOps OIDC](https://docs.aws.amazon.com/prescriptive-guidance/latest/patterns/deploy-workloads-from-azure-devops-pipelines-to-private-amazon-eks-clusters.html)

## Secure files

Upload the real backend and variable files to **Pipelines → Library → Secure
files**. Authorize only this pipeline to use them. The pipeline expects these
names:

```text
aws-terraform-01-organization.backend.hcl
aws-terraform-01-organization.tfvars
aws-terraform-02-governance.backend.hcl
aws-terraform-02-governance.tfvars
aws-terraform-03-production.backend.hcl
aws-terraform-03-production.tfvars
aws-terraform-04-entra-access.backend.hcl
aws-terraform-04-entra-access.tfvars
aws-terraform-05-gitlab-oidc.backend.hcl
aws-terraform-05-gitlab-oidc.tfvars
```

The files are downloaded to the temporary agent directory, passed to
Terraform with `-backend-config` and `-var-file`, and removed by Azure DevOps
when the job completes. They must not be copied into the repository or
published as artifacts. See [Azure DevOps secure files](https://learn.microsoft.com/en-us/azure/devops/pipelines/library/secure-files?view=azure-devops).

The pipeline overrides the local `management_profile` or `aws_profile` value
from those files with an empty profile during planning. This prevents the
host-oriented profile names in the example configuration from causing a
pipeline run to search for a local credentials file instead of using OIDC.

## Azure WIF for stage 04

Stage 04 uses the AzureAD provider's Azure CLI authentication path. Create an
Azure Resource Manager service connection named `azure-entra-wif`, or provide a
different name through `azure_service_connection` when manually running the
pipeline. Configure it with workload identity federation and grant only the
Entra permissions required to manage the two groups.

The stage 04 job authenticates to AWS for its S3 backend and to Azure for the
AzureAD provider, then verifies both identities with:

```bash
aws sts get-caller-identity
az account show
```

Stage 04 only creates the Terraform-managed Entra groups. SAML identity-source
cutover, SCIM provisioning, certificate handling, and federation assignments
remain subject to the existing [production federation runbook](entra-aws-federation-production-runbook.md).

## Run behavior

- Pull requests targeting `main` run formatting, validation, and plans only.
- A `main` run plans and publishes one protected plan artifact per stage, then
  waits at the corresponding environment before applying that exact plan.
- Stages are planned and applied one at a time so a plan depending on accounts
  created by stage 01 is not generated before stage 01 is applied.
- `enable_entra_access` and `enable_gitlab_oidc` default to `false`. Enable
  either explicitly for a reviewed manual run.
- Stage 05 requires the private GitLab metadata synchronization preconditions
  documented in [the GitLab OIDC runbook](gitlab-private-oidc-runbook.md).

The saved plan artifact includes the source commit and stage name. The apply
job refuses to continue if either does not match the current pipeline run. The
pipeline never runs an unplanned `terraform apply`.

## First run checklist

1. Apply stage 00 manually and verify each later backend points to the state
   bucket.
2. Create the AWS OIDC provider, restricted Terraform role, and AWS Toolkit
   service connection.
3. Upload and authorize the secure files listed above.
4. Create the deployment environments and configure approvals/checks.
5. Create the Azure WIF service connection before enabling stage 04.
6. Create the pipeline from the committed `azure-pipelines.yml` file.
7. Run a pull request validation and review the plans before merging.
