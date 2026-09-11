resource "aws_sns_topic" "this" {
  name              = var.topic_name
  kms_master_key_id = "alias/aws/sns"
  tags              = merge(var.tags, { Name = var.topic_name })
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn              = aws_sns_topic.this.arn
  protocol               = "email"
  endpoint               = var.notification_email
  endpoint_auto_confirms = false
}
