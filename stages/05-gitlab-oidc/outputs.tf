output "gitlab_oidc_issuer_url" {
  description = "Public issuer URL to configure in GitLab and AWS IAM."
  value       = local.oidc_issuer_url
}

output "gitlab_oidc_bucket_name" {
  description = "Private S3 bucket receiving the two mirrored GitLab OIDC documents."
  value       = aws_s3_bucket.gitlab_oidc.id
}

output "gitlab_oidc_distribution_id" {
  description = "CloudFront distribution ID for optional metadata invalidations."
  value       = aws_cloudfront_distribution.gitlab_oidc.id
}

output "gitlab_oidc_role_arn" {
  description = "Production-account GitLab role ARN, when IAM resources are enabled."
  value       = try(aws_iam_role.gitlab[0].arn, null)
}

output "gitlab_oidc_provider_arn" {
  description = "Production-account IAM OIDC provider ARN, when IAM resources are enabled."
  value       = try(aws_iam_openid_connect_provider.gitlab[0].arn, null)
}
