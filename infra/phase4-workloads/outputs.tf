output "ecr_repository_names" {
  description = "Repository names for the ECR_REPOSITORY deployment input."
  value       = { for service, registry in module.ecr : service => registry.repository_name }
}

output "runtime_config" {
  description = "Non-secret values to merge into the three Kubernetes ConfigMaps."
  value = {
    "garageflow-saga-config" = {
      AWS_REGION                                                = var.aws_region
      Integrations__ExecutionScheduling__Enabled                = "true"
      Integrations__ExecutionScheduling__CommandQueueUrl        = aws_sqs_queue.work["execution-commands"].url
      Integrations__ExecutionScheduling__ResultQueueUrl         = aws_sqs_queue.work["execution-results"].url
      Integrations__ExecutionScheduling__BillingCommandQueueUrl = aws_sqs_queue.work["billing-commands"].url
      Integrations__ExecutionScheduling__BillingResultQueueUrl  = aws_sqs_queue.work["billing-results"].url
    }
    "garageflow-execution-config" = {
      AWS_REGION                = var.aws_region
      Execution__InputQueueUrl  = aws_sqs_queue.work["execution-commands"].url
      Execution__ResultQueueUrl = aws_sqs_queue.work["execution-results"].url
      Execution__TableName      = aws_dynamodb_table.execution.name
    }
    "garageflow-billing-config" = {
      AWS_REGION               = var.aws_region
      Billing__CommandQueueUrl = aws_sqs_queue.work["billing-commands"].url
      Billing__ResultQueueUrl  = aws_sqs_queue.work["billing-results"].url
    }
  }
}

output "workload_policies" {
  description = "Attach each document to its corresponding pre-existing IAM role before running the workloads."
  value = {
    for service, access in local.services : service => {
      Version = "2012-10-17"
      Statement = concat([
        {
          Effect   = "Allow"
          Action   = ["sqs:ReceiveMessage", "sqs:DeleteMessage"]
          Resource = [for flow in access.reads : aws_sqs_queue.work[flow].arn]
        },
        {
          Effect   = "Allow"
          Action   = ["sqs:SendMessage"]
          Resource = [for flow in access.writes : aws_sqs_queue.work[flow].arn]
        }
        ], service == "execution" ? [{
          Effect   = "Allow"
          Action   = ["dynamodb:GetItem", "dynamodb:PutItem"]
          Resource = [aws_dynamodb_table.execution.arn]
      }] : [])
    }
  }
}
