# Private GitLab OIDC metadata mirror

Stage `05-gitlab-oidc` creates a private, versioned S3 bucket and a CloudFront distribution that exposes only the two OIDC metadata objects AWS needs from a non-public GitLab instance:

```text
/.well-known/openid-configuration
/oauth/discovery/keys
```

The GitLab UI, API, runners, and authentication endpoints remain private. CloudFront uses Origin Access Control, so the S3 bucket does not need public access.

## Important boundary

The public discovery document and JWKS are security-sensitive. A malicious change to either can affect every AWS role that trusts this issuer. Use a separately controlled bucket/account where practical, restrict write access to the two object ARNs, enable versioning, and monitor changes.

The synchronization script reads the private GitLab endpoints without credentials, rewrites `issuer` and `jwks_uri` to the public issuer, validates that signing keys exist, and uploads only the two approved objects. It publishes JWKS before the discovery document when an update is needed.

## Bootstrap sequence

### 1. Create the mirror and CloudFront distribution

Copy and edit the example files. Use the state bucket created by stage 00 or another approved remote backend.

```bash
cp stages/05-gitlab-oidc/terraform.tfvars.example stages/05-gitlab-oidc/terraform.tfvars
cp stages/05-gitlab-oidc/backend.hcl.example stages/05-gitlab-oidc/backend.hcl
terraform -chdir=stages/05-gitlab-oidc init -backend-config=backend.hcl
terraform -chdir=stages/05-gitlab-oidc plan -out=gitlab-oidc-mirror.tfplan
```

Review that this first plan creates only the private bucket, CloudFront distribution, OAC, and bucket policy. Do not enable `enable_iam_oidc_provider` or `create_gitlab_role` yet.

Apply only the reviewed saved plan:

```bash
terraform -chdir=stages/05-gitlab-oidc apply gitlab-oidc-mirror.tfplan
terraform -chdir=stages/05-gitlab-oidc output -raw issuer_url
```

CloudFront deployment can take several minutes. The output is the stable public issuer URL, normally a `https://d*.cloudfront.net` URL.

### 2. Configure GitLab’s issuer

For a Linux package installation, set the public issuer in `/etc/gitlab/gitlab.rb`:

```ruby
gitlab_rails['ci_id_tokens_issuer_url'] = 'https://d123example.cloudfront.net'
```

Run the normal GitLab reconfigure procedure. For Helm or Docker installations, use GitLab’s corresponding `ciIdTokens.issuerUrl` or `GITLAB_OMNIBUS_CONFIG` setting. This is a deliberate GitLab configuration boundary and should be applied through the instance’s normal change process.

### 3. Synchronize the two documents

Run the script from a trusted runner that can reach the private GitLab instance and AWS. Prefer an instance/task role or the narrowly scoped `metadata_sync_role_arn`; do not put long-lived AWS keys in GitLab variables.

```powershell
pwsh .\scripts\Sync-GitLabOidcMetadata.ps1 `
  -GitLabBaseUrl 'https://gitlab.internal.example' `
  -PublicIssuerUrl 'https://d123example.cloudfront.net' `
  -MetadataBucket 'replace-with-the-bucket-name' `
  -AwsProfile 'gitlab-oidc-sync' `
  -AwsRegion 'us-east-1' `
  -ValidatePublic
```

If CloudFront has not finished deploying, run the upload first and run the same command with `-ValidatePublic` later. Use `-WhatIf` to inspect the two intended uploads without changing S3.

The source GitLab discovery and JWKS endpoints must be reachable from the trusted runner. The script refuses to publish an empty key set or a discovery document missing `issuer` or `jwks_uri`.

### Pseudo-GitLab end-to-end test

After the IAM provider and workload role exist, run the pseudo-GitLab test from a host that can reach the private AWS resources. It starts a loopback-only synthetic GitLab issuer, generates a temporary RSA signing key and JWT, runs the real synchronization script, and asks AWS CLI to exchange the JWT through the configured role. No real GitLab endpoint or credential is used.

```powershell
pwsh .\scripts\Invoke-PseudoGitLabOidcTest.ps1 `
  -PublicIssuerUrl 'https://d123example.cloudfront.net' `
  -MetadataBucket 'replace-with-the-bucket-name' `
  -RoleArn 'arn:aws:iam::000000000000:role/GitLabTerraform' `
  -AllowedSubject 'project_path:platform/terraform:ref_type:branch:ref:main' `
  -AwsProfile 'management' `
  -AwsRegion 'us-east-1'
```

The command should report `Result: passed` and the assumed role ARN. It intentionally tests the AWS-side issuer, JWKS retrieval, audience, subject, signature, and STS exchange; it does not test GitLab pipeline claim generation or GitLab network policy.

### 4. Enable the AWS IAM provider

After the public endpoints validate, set:

```hcl
enable_iam_oidc_provider = true
```

Run a new plan. The IAM provider URL must equal the output `issuer_url`, and the `oidc_audience` must match both the IAM provider and the GitLab job’s `id_tokens` configuration.

### 5. Create the workload role only after reviewing permissions

Set `create_gitlab_role = true`, provide exact protected-ref subjects, and attach only reviewed workload policies:

```hcl
allowed_subjects = [
  "project_path:platform/terraform:ref_type:branch:ref:main",
]

gitlab_role_policy_arns = [
  # Add only the policy or policies required by this Terraform workload.
]
```

For self-managed GitLab, AWS trust conditions should use the issuer host with `aud` and `sub`. Avoid broad wildcard subjects. If the project is renamed, the default path-based subject changes; consider configuring GitLab’s subject components to include the project ID, then use that exact resulting `sub` value.

### 6. Use the role in GitLab CI

The consuming project should use an ID token, not the removed `CI_JOB_JWT_V2` variable:

```yaml
terraform:
  id_tokens:
    AWS_OIDC_TOKEN:
      aud: sts.amazonaws.com

  script:
    - >-
      aws sts assume-role-with-web-identity
      --role-arn "$AWS_ROLE_ARN"
      --role-session-name "GitLab-${CI_PROJECT_ID}-${CI_PIPELINE_ID}"
      --web-identity-token "$AWS_OIDC_TOKEN"
```

The role session must be checked with `aws sts get-caller-identity` before applying infrastructure. Keep production applies limited to protected branches/tags and trusted runners.

## Ongoing synchronization

Run `Sync-GitLabOidcMetadata.ps1` on a schedule from a trusted private runner. A scheduled pipeline is appropriate when the runner has private GitLab connectivity and its AWS identity can assume the metadata sync role. A host-level timer is also acceptable. The job should:

1. Fetch the private discovery document and JWKS.
2. Validate the signing key set.
3. Upload only the two objects, with short cache control.
4. Fetch both public CloudFront URLs and verify the public issuer, JWKS URI, and non-empty key set.

The script compares SHA-256 metadata before writing, so an unchanged synchronization does not create a new S3 version.

## Acceptance checks

```bash
ISSUER_URL="$(terraform -chdir=stages/05-gitlab-oidc output -raw issuer_url)"
curl --fail --silent --show-error "$ISSUER_URL/.well-known/openid-configuration" | jq '{issuer,jwks_uri}'
curl --fail --silent --show-error "$ISSUER_URL/oauth/discovery/keys" | jq '{key_count: (.keys | length)}'
terraform -chdir=stages/05-gitlab-oidc validate
```

Do not claim the integration is complete until a real protected GitLab job successfully obtains temporary AWS credentials and `aws sts get-caller-identity` shows the intended role.
