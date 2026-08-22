output "metadata_bucket_name" {
  description = "Private S3 bucket containing the synchronized OIDC metadata."
  value       = aws_s3_bucket.oidc_metadata.id
}

output "cloudfront_distribution_id" {
  description = "CloudFront distribution serving the two public OIDC metadata objects."
  value       = aws_cloudfront_distribution.oidc_metadata.id
}

output "issuer_url" {
  description = "Public issuer URL to use in GitLab and the AWS IAM OIDC provider."
  value       = local.issuer_url
}

output "openid_configuration_url" {
  description = "Public OpenID configuration endpoint."
  value       = "${local.issuer_url}/.well-known/openid-configuration"
}

output "jwks_url" {
  description = "Public JSON Web Key Set endpoint."
  value       = "${local.issuer_url}/oauth/discovery/keys"
}

output "iam_oidc_provider_arn" {
  description = "AWS IAM OIDC provider ARN, when enabled after metadata bootstrap."
  value       = try(aws_iam_openid_connect_provider.gitlab[0].arn, null)
}

output "gitlab_role_arn" {
  description = "Optional IAM workload role ARN for GitLab CI."
  value       = try(aws_iam_role.gitlab[0].arn, null)
}

output "metadata_sync_role_arn" {
  description = "Optional least-privilege role ARN for the trusted metadata synchronization runner."
  value       = try(aws_iam_role.metadata_sync[0].arn, null)
}
