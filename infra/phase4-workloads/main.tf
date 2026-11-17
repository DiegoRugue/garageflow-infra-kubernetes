locals {
  prefix = "garageflow-${var.environment}"
  flows  = toset(["execution-commands", "execution-results", "billing-commands", "billing-results"])
  services = {
    api = {
      reads  = ["execution-results", "billing-results"]
      writes = ["execution-commands", "billing-commands"]
    }
    execution = {
      reads  = ["execution-commands"]
      writes = ["execution-results"]
    }
    billing = {
      reads  = ["billing-commands"]
      writes = ["billing-results"]
    }
  }
}

resource "aws_sqs_queue" "dead_letter" {
  for_each = local.flows

  name                      = "${local.prefix}-${each.key}-dlq"
  message_retention_seconds = 1209600
  sqs_managed_sse_enabled   = true
}

resource "aws_sqs_queue" "work" {
  for_each = local.flows

  name                       = "${local.prefix}-${each.key}"
  visibility_timeout_seconds = 90
  receive_wait_time_seconds  = 20
  sqs_managed_sse_enabled    = true

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dead_letter[each.key].arn
    maxReceiveCount     = 5
  })
}

resource "aws_sqs_queue_redrive_allow_policy" "dead_letter" {
  for_each = local.flows

  queue_url = aws_sqs_queue.dead_letter[each.key].url
  redrive_allow_policy = jsonencode({
    redrivePermission = "byQueue"
    sourceQueueArns   = [aws_sqs_queue.work[each.key].arn]
  })
}

resource "aws_dynamodb_table" "execution" {
  name         = "${local.prefix}-execution"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "Id"

  attribute {
    name = "Id"
    type = "S"
  }
}

module "ecr" {
  for_each = toset(["execution", "billing"])
  source   = "../modules/ecr"

  repository_name = "${local.prefix}-${each.key}"
}

resource "aws_eks_pod_identity_association" "workload" {
  for_each = local.services

  cluster_name    = var.cluster_name
  namespace       = "garageflow"
  service_account = "garageflow-${each.key}"
  role_arn        = var.workload_role_arns[each.key]
}
