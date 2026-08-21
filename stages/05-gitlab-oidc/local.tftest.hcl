mock_provider "aws" {
  alias           = "mock"
  override_during = plan

  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "000000000000"
    }
  }

  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
}

run "mirror_only_plan" {
  command = plan

  providers = {
    aws            = aws.mock
    aws.production = aws.mock
  }

  variables {
    management_account_id     = "000000000000"
    management_profile        = "local-test"
    management_region         = "us-east-1"
    production_account_id     = "222222222222"
    production_region         = "us-east-1"
    oidc_bucket_name          = "local-test-gitlab-oidc-mirror"
    create_aws_oidc_resources = false
  }

  assert {
    condition     = aws_s3_bucket.gitlab_oidc.bucket == "local-test-gitlab-oidc-mirror"
    error_message = "The local test must retain the configured OIDC bucket name."
  }

  assert {
    condition     = output.gitlab_oidc_role_arn == null
    error_message = "The first phase must not create the GitLab IAM role."
  }
}

run "iam_resources_apply" {
  command = apply

  providers = {
    aws            = aws.mock
    aws.production = aws.mock
  }

  variables {
    management_account_id     = "000000000000"
    management_profile        = "local-test"
    management_region         = "us-east-1"
    production_account_id     = "222222222222"
    production_region         = "us-east-1"
    oidc_bucket_name          = "local-test-gitlab-oidc-mirror"
    create_aws_oidc_resources = true
    gitlab_subject            = "project_path:example/group/project:ref_type:branch:ref:main"
    gitlab_role_policy_json = jsonencode({
      Version = "2012-10-17"
      Statement = [{
        Effect   = "Allow"
        Action   = ["sts:GetCallerIdentity"]
        Resource = "*"
      }]
    })
  }

  assert {
    condition     = output.gitlab_oidc_role_arn != null
    error_message = "The second phase must create a GitLab IAM role ARN."
  }
}
