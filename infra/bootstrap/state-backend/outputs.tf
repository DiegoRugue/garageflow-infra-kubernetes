output "state_bucket_name" {
  description = "Name of the retained S3 Terraform state bucket."
  value       = aws_s3_bucket.state.bucket
}

output "state_bucket_arn" {
  description = "ARN of the retained S3 Terraform state bucket."
  value       = aws_s3_bucket.state.arn
}

output "state_access_log_bucket_name" {
  description = "Name of the S3 bucket receiving Terraform state access logs."
  value       = aws_s3_bucket.state_logs.bucket
}
