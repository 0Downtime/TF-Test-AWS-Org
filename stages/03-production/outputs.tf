output "secret_arn" {
  description = "Baseline production secret ARN."
  value       = aws_secretsmanager_secret.production.arn
}

output "production_secrets_role_arn" {
  description = "Optional least-privilege production secret role ARN."
  value       = try(aws_iam_role.production_secrets[0].arn, null)
}

output "production_secrets_read_policy_arn" {
  description = "Optional read-only Secrets Manager policy ARN."
  value       = try(aws_iam_policy.production_secrets_read[0].arn, null)
}

output "production_secrets_read_write_policy_arn" {
  description = "Optional read/write Secrets Manager policy ARN."
  value       = try(aws_iam_policy.production_secrets_read_write[0].arn, null)
}
