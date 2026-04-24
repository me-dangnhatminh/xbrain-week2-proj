output "alb_public_url" {
  description = "Đường link dùng để vào website"
  value       = "http://${module.compute.alb_dns_name}"
}

output "cloudfront_cdn_url" {
  description = "Đường link CloudFront CDN (HTTPS)"
  value       = "https://${module.storage.cloudfront_domain_name}"
}

output "ecr_repository_url" {
  description = "Kho ECR chứa Container Image"
  value       = module.compute.ecr_repository_url
}


output "api_gateway_https_url" {
  description = "Duong link HTTPS an toan cua Backend thong qua API Gateway proxy"
  value       = module.compute.api_gateway_url
}

output "bedrock_chat_lambda" {
  description = "Ten Lambda function cho Bedrock AI Chat"
  value       = module.lambda.lambda_function_name
}

