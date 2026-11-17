locals {
  platform = var.platform_contract.outputs
  prefix   = "garageflow-${var.environment}"
  flows    = toset(["execution-commands", "execution-results", "billing-commands", "billing-results"])
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

data "aws_eks_cluster" "platform" { name = local.platform.clusterName }

resource "terraform_data" "platform_identity" {
  lifecycle {
    precondition {
      condition = (
        data.aws_eks_cluster.platform.arn == "arn:aws:eks:${var.aws_region}:${var.aws_account_id}:cluster/${local.platform.clusterName}" &&
        lookup(data.aws_eks_cluster.platform.tags, "Environment", "") == var.environment &&
        data.aws_eks_cluster.platform.vpc_config[0].vpc_id == local.platform.vpcId &&
        data.aws_eks_cluster.platform.vpc_config[0].cluster_security_group_id == local.platform.clusterSecurityGroupId
      )
      error_message = "The live EKS cluster must match the platform contract and the selected environment."
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
  for_each = var.workload_role_arns == null ? tomap({}) : tomap(var.workload_role_arns)

  cluster_name    = local.platform.clusterName
  namespace       = "garageflow"
  service_account = "garageflow-${each.key}"
  role_arn        = each.value
  depends_on      = [terraform_data.platform_identity]
}
