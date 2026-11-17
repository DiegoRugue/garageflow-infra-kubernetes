mock_provider "aws" {}

variables {
  environment    = "homologation"
  aws_account_id = "123456789012"
  cluster_name   = "garageflow-homologation"
  workload_role_arns = {
    api       = "arn:aws:iam::123456789012:role/garageflow-api"
    execution = "arn:aws:iam::123456789012:role/garageflow-execution"
    billing   = "arn:aws:iam::123456789012:role/garageflow-billing"
  }
}

run "wire_saga_workloads" {
  command = apply

  assert {
    condition = alltrue([
      for flow, queue in aws_sqs_queue.work :
      queue.sqs_managed_sse_enabled &&
      jsondecode(queue.redrive_policy).deadLetterTargetArn == aws_sqs_queue.dead_letter[flow].arn &&
      jsondecode(queue.redrive_policy).maxReceiveCount == 5 &&
      jsondecode(aws_sqs_queue_redrive_allow_policy.dead_letter[flow].redrive_allow_policy).sourceQueueArns[0] == queue.arn
    ]) && length(aws_sqs_queue.work) == 4
    error_message = "Every Saga flow must have its own encrypted queue and matching dead-letter queue."
  }

  assert {
    condition = (
      output.runtime_config["garageflow-saga-config"].Integrations__ExecutionScheduling__CommandQueueUrl ==
      output.runtime_config["garageflow-execution-config"].Execution__InputQueueUrl
      &&
      output.runtime_config["garageflow-saga-config"].Integrations__ExecutionScheduling__ResultQueueUrl ==
      output.runtime_config["garageflow-execution-config"].Execution__ResultQueueUrl
      &&
      output.runtime_config["garageflow-saga-config"].Integrations__ExecutionScheduling__BillingCommandQueueUrl ==
      output.runtime_config["garageflow-billing-config"].Billing__CommandQueueUrl
      &&
      output.runtime_config["garageflow-saga-config"].Integrations__ExecutionScheduling__BillingResultQueueUrl ==
      output.runtime_config["garageflow-billing-config"].Billing__ResultQueueUrl
    )
    error_message = "The producer and consumer must agree on all four queue URLs."
  }

  assert {
    condition = (
      aws_dynamodb_table.execution.hash_key == "Id"
      && aws_dynamodb_table.execution.billing_mode == "PAY_PER_REQUEST"
      && output.runtime_config["garageflow-execution-config"].Execution__TableName == aws_dynamodb_table.execution.name
      && length(output.ecr_repository_names) == 2
    )
    error_message = "Execution must have its own table and both workers must have their own image registry."
  }

  assert {
    condition = alltrue([
      for service, binding in aws_eks_pod_identity_association.workload :
      binding.namespace == "garageflow" && binding.service_account == "garageflow-${service}" &&
      binding.role_arn == var.workload_role_arns[service]
    ]) && length(aws_eks_pod_identity_association.workload) == 3
    error_message = "Each workload must use its own Pod Identity association."
  }
}

run "reject_shared_workload_role" {
  command = plan

  variables {
    workload_role_arns = {
      api       = "arn:aws:iam::123456789012:role/shared"
      execution = "arn:aws:iam::123456789012:role/shared"
      billing   = "arn:aws:iam::123456789012:role/shared"
    }
  }

  expect_failures = [var.workload_role_arns]
}
