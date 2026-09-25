# ---------------------------------------------------------------------------
# HTTP API. This is the internet-facing entry point (no load balancer).
# ---------------------------------------------------------------------------
resource "aws_apigatewayv2_api" "main" {
  name          = var.name
  protocol_type = "HTTP"
}

# ---------------------------------------------------------------------------
# VPC Link: the plumbing that lets the HTTP API reach into the VPC. For HTTP
# APIs this has no hourly charge and needs no NLB (unlike REST API VPC links).
# ---------------------------------------------------------------------------
resource "aws_apigatewayv2_vpc_link" "main" {
  name               = var.name
  subnet_ids         = aws_subnet.vpclink[*].id
  security_group_ids = [aws_security_group.vpclink.id]
}

# ---------------------------------------------------------------------------
# Private integration targeting the Cloud Map service directly. No ALB/NLB:
# integration_uri is the Cloud Map service ARN.
# ---------------------------------------------------------------------------
resource "aws_apigatewayv2_integration" "app" {
  api_id             = aws_apigatewayv2_api.main.id
  integration_type   = "HTTP_PROXY"
  integration_method = "ANY"
  connection_type    = "VPC_LINK"
  connection_id      = aws_apigatewayv2_vpc_link.main.id
  integration_uri    = aws_service_discovery_service.app.arn
}

# Catch-all route -> integration.
resource "aws_apigatewayv2_route" "default" {
  api_id    = aws_apigatewayv2_api.main.id
  route_key = "ANY /{proxy+}"
  target    = "integrations/${aws_apigatewayv2_integration.app.id}"
}

# Auto-deploy stage.
resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.main.id
  name        = "$default"
  auto_deploy = true
}
