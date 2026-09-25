output "url" {
  description = "Public URL for the service (API Gateway HTTP API endpoint)."
  value       = aws_apigatewayv2_api.main.api_endpoint
}
