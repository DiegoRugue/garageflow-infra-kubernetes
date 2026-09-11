resource "random_password" "jwt" {
  length  = 64
  special = false
}

resource "random_password" "internal_auth" {
  length  = 64
  special = false
}

resource "random_password" "webhook" {
  length  = 64
  special = false
}

resource "random_password" "bootstrap_initial" {
  length           = 24
  special          = true
  override_special = "!@#%_-"
  min_upper        = 1
  min_lower        = 1
  min_numeric      = 1
  min_special      = 1
}

resource "random_password" "bootstrap_active" {
  length           = 24
  special          = true
  override_special = "!@#%_-"
  min_upper        = 1
  min_lower        = 1
  min_numeric      = 1
  min_special      = 1
}

resource "aws_secretsmanager_secret" "jwt" {
  name                    = "garageflow/${var.environment}/jwt"
  recovery_window_in_days = 0
  tags                    = var.tags
}

resource "aws_secretsmanager_secret_version" "jwt" {
  secret_id     = aws_secretsmanager_secret.jwt.id
  secret_string = random_password.jwt.result
}

resource "aws_secretsmanager_secret" "internal_auth" {
  name                    = "garageflow/${var.environment}/internal-auth"
  recovery_window_in_days = 0
  tags                    = var.tags
}

resource "aws_secretsmanager_secret_version" "internal_auth" {
  secret_id     = aws_secretsmanager_secret.internal_auth.id
  secret_string = random_password.internal_auth.result
}

resource "aws_secretsmanager_secret" "bootstrap" {
  name                    = "garageflow/${var.environment}/bootstrap"
  recovery_window_in_days = 0
  tags                    = var.tags
}

resource "aws_secretsmanager_secret_version" "bootstrap" {
  secret_id = aws_secretsmanager_secret.bootstrap.id
  secret_string = jsonencode({
    email           = var.bootstrap_admin_email
    initialPassword = random_password.bootstrap_initial.result
    activePassword  = random_password.bootstrap_active.result
  })
}

resource "aws_secretsmanager_secret" "webhook" {
  name                    = "garageflow/${var.environment}/webhook"
  recovery_window_in_days = 0
  tags                    = var.tags
}

resource "aws_secretsmanager_secret_version" "webhook" {
  secret_id     = aws_secretsmanager_secret.webhook.id
  secret_string = random_password.webhook.result
}
