data "aws_caller_identity" "current" {}

locals {
  state_access_log_bucket_name = "${substr(replace(var.state_bucket_name, ".", "-"), 0, 47)}-${substr(sha256(var.state_bucket_name), 0, 8)}-logs"
  state_access_log_prefix      = "state-access/"
}

resource "aws_s3_bucket" "state" {
  bucket = var.state_bucket_name

  tags = merge(var.tags, {
    Project   = "GarageFlow"
    Phase     = "3"
    Owner     = var.owner
    ExpiresOn = var.expires_on
    ManagedBy = "Terraform"
  })

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket" "state_logs" {
  bucket = local.state_access_log_bucket_name

  tags = merge(var.tags, {
    Project   = "GarageFlow"
    Phase     = "3"
    Owner     = var.owner
    ExpiresOn = var.expires_on
    ManagedBy = "Terraform"
    Purpose   = "TerraformStateAccessLogs"
  })
}

resource "aws_s3_bucket_versioning" "state_logs" {
  bucket = aws_s3_bucket.state_logs.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state_logs" {
  bucket = aws_s3_bucket.state_logs.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "state_logs" {
  bucket = aws_s3_bucket.state_logs.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "state_logs" {
  bucket = aws_s3_bucket.state_logs.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "state_logs" {
  bucket = aws_s3_bucket.state_logs.id

  rule {
    id     = "expire-state-access-logs"
    status = "Enabled"

    filter {
      prefix = local.state_access_log_prefix
    }

    expiration {
      days = 30
    }

    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }

  depends_on = [aws_s3_bucket_versioning.state_logs]
}

data "aws_iam_policy_document" "state_logs" {
  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.state_logs.arn,
      "${aws_s3_bucket.state_logs.arn}/*"
    ]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }

  statement {
    sid    = "AllowS3ServerAccessLogDelivery"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["logging.s3.amazonaws.com"]
    }

    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.state_logs.arn}/${local.state_access_log_prefix}*"]

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = [aws_s3_bucket.state.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_s3_bucket_policy" "state_logs" {
  bucket = aws_s3_bucket.state_logs.id
  policy = data.aws_iam_policy_document.state_logs.json
}

resource "aws_s3_bucket_logging" "state" {
  bucket        = aws_s3_bucket.state.id
  target_bucket = aws_s3_bucket.state_logs.id
  target_prefix = local.state_access_log_prefix

  depends_on = [
    aws_s3_bucket_ownership_controls.state_logs,
    aws_s3_bucket_public_access_block.state_logs,
    aws_s3_bucket_policy.state_logs
  ]
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket = aws_s3_bucket.state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

data "aws_iam_policy_document" "state_transport" {
  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.state.arn,
      "${aws_s3_bucket.state.arn}/*"
    ]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "state_transport" {
  bucket = aws_s3_bucket.state.id
  policy = data.aws_iam_policy_document.state_transport.json
}

resource "aws_s3_bucket_ownership_controls" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}
