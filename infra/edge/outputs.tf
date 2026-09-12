output "api_url" {
  description = "Public managed HTTPS endpoint; no custom domain or certificate required."
  value       = aws_apigatewayv2_stage.live.invoke_url
}
