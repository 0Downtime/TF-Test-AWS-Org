# Private GitLab OIDC runbook

This runbook configures GitLab Self-Managed CI/CD to obtain temporary AWS credentials without storing an AWS access key in GitLab.

The AWS OIDC provider is created in the production account. The public metadata mirror is hosted in the management account in a private S3 bucket behind CloudFront. The existing Terraform-state and CloudTrail buckets remain private and are not reused.

## Prerequisites

- GitLab Self-Managed 18.1 or later with ID-token support.
- A GitLab instance that is private to users and runners but can serve its OIDC discovery and JWKS endpoints to the local sync host.
- AWS CLI v2, Terraform, and PowerShell 7 on the sync host.
- A globally unique S3 bucket name.
- A protected GitLab project branch that should be allowed to assume the role.
- A reviewed least-privilege policy for the workload. Leave the role without permissions until that policy is known.

## Phase 1: Create the mirror

Copy the stage examples and set the management and production account IDs:

```bash
cp stages/05-gitlab-oidc/terraform.tfvars.example stages/05-gitlab-oidc/terraform.tfvars
cp stages/05-gitlab-oidc/backend.hcl.example stages/05-gitlab-oidc/backend.hcl
terraform -chdir=stages/05-gitlab-oidc init -backend-config=backend.hcl
terraform -chdir=stages/05-gitlab-oidc plan -out=gitlab-oidc-mirror.tfplan
terraform -chdir=stages/05-gitlab-oidc apply gitlab-oidc-mirror.tfplan
terraform -chdir=stages/05-gitlab-oidc output
```

Keep `create_aws_oidc_resources = false` for this apply. Record these outputs:

- `gitlab_oidc_issuer_url`
- `gitlab_oidc_bucket_name`
- `gitlab_oidc_distribution_id`

## Phase 2: Publish GitLab metadata

Run the sync script from a machine that can reach the private GitLab instance. It fetches the private discovery and JWKS documents, rewrites only `issuer` and `jwks_uri`, publishes JWKS first, then invalidates the two CloudFront paths.

```powershell
pwsh .\scripts\Publish-GitLabOidcMetadata.ps1 `
  -GitLabBaseUrl https://gitlab.internal.example `
  -IssuerUrl https://<cloudfront-domain-from-output> `
  -BucketName <bucket-name-from-output> `
  -DistributionId <distribution-id-from-output> `
  -AwsProfile management `
  -AwsRegion us-east-1
```

The sync identity needs only `s3:PutObject` for:

```text
<bucket>/.well-known/openid-configuration
<bucket>/oauth/discovery/keys
```

It also needs `cloudfront:CreateInvalidation` for the one distribution. Do not put credentials, tokens, or private keys in Terraform variables, the repository, or the GitLab job.

Verify the public documents before changing GitLab:

```bash
curl --fail --silent https://<cloudfront-domain>/.well-known/openid-configuration | jq .
curl --fail --silent https://<cloudfront-domain>/oauth/discovery/keys | jq .
```

The discovery document's `issuer` must exactly equal the CloudFront URL, and its `jwks_uri` must use the public CloudFront URL.

## Phase 3: Configure GitLab

For Omnibus GitLab, set the public issuer URL in `/etc/gitlab/gitlab.rb`:

```ruby
gitlab_rails['ci_id_tokens_issuer_url'] = 'https://<cloudfront-domain>'
```

Then run:

```bash
sudo gitlab-ctl reconfigure
sudo gitlab-rake ci:validate_id_token_configuration
```

For Helm, set `global.appConfig.ciIdTokens.issuerUrl`. For Docker, set the equivalent `GITLAB_OMNIBUS_CONFIG` value. The GitLab issuer and the public discovery `issuer` must remain identical.

## Phase 4: Create the AWS provider and role

Set these values in the ignored `terraform.tfvars`:

```hcl
create_aws_oidc_resources = true
gitlab_subject            = "project_path:YOUR_GROUP/YOUR_PROJECT:ref_type:branch:ref:main"

gitlab_role_policy_json = jsonencode({
  Version = "2012-10-17"
  Statement = [{
    Effect   = "Allow"
    Action   = ["sts:GetCallerIdentity"]
    Resource = "*"
  }]
})
```

Replace the example policy with the exact permissions needed by the deployment. Use `StringEquals` and an exact protected branch subject whenever possible. Self-Managed GitLab exposes only `sub` and `aud` as AWS trust-policy condition keys; it does not expose GitLab.com-only `project_id` and `namespace_id` keys.

Review and apply the saved plan:

```bash
terraform -chdir=stages/05-gitlab-oidc plan -out=gitlab-oidc-role.tfplan
terraform -chdir=stages/05-gitlab-oidc apply gitlab-oidc-role.tfplan
terraform -chdir=stages/05-gitlab-oidc output gitlab_oidc_role_arn
```

## Phase 5: Test from GitLab

Use an ID token with the same audience configured in Terraform:

```yaml
deploy-to-aws:
  image: amazon/aws-cli:2
  id_tokens:
    GITLAB_OIDC_TOKEN:
      aud: sts.amazonaws.com
  variables:
    AWS_ROLE_ARN: arn:aws:iam::<production-account-id>:role/GitLabProductionDeploy
    AWS_DEFAULT_REGION: us-east-1
  script:
    - printf '%s' "$GITLAB_OIDC_TOKEN" > "$CI_PROJECT_DIR/.gitlab-oidc-token"
    - export AWS_WEB_IDENTITY_TOKEN_FILE="$CI_PROJECT_DIR/.gitlab-oidc-token"
    - aws sts get-caller-identity
```

The job runner needs outbound access to AWS STS and the target AWS APIs. AWS STS, not the runner, must be able to retrieve the public issuer configuration and JWKS.

## Ongoing operation

Run the metadata sync on a schedule and after GitLab signing-key changes. Publish JWKS before the discovery document. A stale mirror causes valid tokens to fail; an unauthorized write to the mirror can allow forged tokens, so monitor the bucket, CloudFront, and sync identity with CloudTrail.
