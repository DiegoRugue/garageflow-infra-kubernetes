output "jwt_secret_arn" {
  description = "ARN of the JWT signing secret; the secret value is never output."
  value       = aws_secretsmanager_secret.jwt.arn
}

output "internal_auth_secret_arn" {
  description = "ARN of the internal service-authentication secret; the secret value is never output."
  value       = aws_secretsmanager_secret.internal_auth.arn
}

output "bootstrap_secret_arn" {
  description = "ARN of the bootstrap administrator secret; the secret value is never output."
  value       = aws_secretsmanager_secret.bootstrap.arn
}

output "webhook_secret_arn" {
  description = "ARN of the estimate-decision webhook secret; the secret value is never output."
  value       = aws_secretsmanager_secret.webhook.arn
}

output "secret_names" {
  description = "Non-sensitive secret names used by offline ownership tests."
  value = [
    aws_secretsmanager_secret.jwt.name,
    aws_secretsmanager_secret.internal_auth.name,
    aws_secretsmanager_secret.bootstrap.name,
    aws_secretsmanager_secret.webhook.name,
  ]
}
