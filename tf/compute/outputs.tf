output "alb_dns_name" {
  value = aws_lb.main.dns_name
}

output "ecr_repository_url" {
  value = aws_ecr_repository.backend.repository_url
}

output "api_gateway_url" {
  value = aws_apigatewayv2_api.backend_api.api_endpoint
}
