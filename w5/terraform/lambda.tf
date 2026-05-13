# =============================================================================
# Lambda: KB Auto-Sync Function
# =============================================================================

resource "aws_iam_role" "lambda_kb_sync" {
  name = "${var.project_name}-kb-sync-lambda-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda_kb_sync.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "lambda_kb_sync" {
  name = "kb-sync-permissions"
  role = aws_iam_role.lambda_kb_sync.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["bedrock:StartIngestionJob", "bedrock:GetIngestionJob"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:ListBucket"]
        Resource = [aws_s3_bucket.knowledge_base.arn, "${aws_s3_bucket.knowledge_base.arn}/*"]
      },
      {
        Effect   = "Allow"
        Action   = ["sqs:SendMessage"]
        Resource = aws_sqs_queue.lambda_dlq.arn
      }
    ]
  })
}

resource "aws_lambda_function" "kb_auto_sync" {
  function_name = "${var.project_name}-kb-auto-sync-${var.environment}"
  role          = aws_iam_role.lambda_kb_sync.arn
  handler       = "kb_auto_sync_lambda.handler"
  runtime       = "python3.11"
  timeout       = 60
  filename      = "${path.module}/../backend/lambda/kb_auto_sync_lambda.zip"

  environment {
    variables = {
      BEDROCK_KB_ID = "QCQW1UU9BM"
      BEDROCK_DS_ID = "B56IWAZSLQ"
    }
  }

  tags = {
    Name        = "${var.project_name}-kb-auto-sync"
    Environment = var.environment
  }
}

# S3 trigger: sync KB when documents change
resource "aws_lambda_permission" "s3_invoke" {
  statement_id  = "AllowS3Invoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.kb_auto_sync.function_name
  principal     = "s3.amazonaws.com"
  source_arn    = aws_s3_bucket.knowledge_base.arn
}

resource "aws_s3_bucket_notification" "kb_sync_trigger" {
  bucket = aws_s3_bucket.knowledge_base.id

  lambda_function {
    lambda_function_arn = aws_lambda_function.kb_auto_sync.arn
    events              = ["s3:ObjectCreated:*", "s3:ObjectRemoved:*"]
    filter_prefix       = "knowledge_base/"
    filter_suffix       = ".md"
  }

  depends_on = [aws_lambda_permission.s3_invoke]
}

# =============================================================================
# MH4: API Gateway + Auth + Throttling
# =============================================================================

resource "aws_api_gateway_rest_api" "sync" {
  name        = "${var.project_name}-sync-api"
  description = "API Gateway for GeekBrain KB sync Lambda"
  endpoint_configuration { types = ["REGIONAL"] }
  tags = { Name = "${var.project_name}-sync-api" }
}

resource "aws_api_gateway_resource" "sync" {
  rest_api_id = aws_api_gateway_rest_api.sync.id
  parent_id   = aws_api_gateway_rest_api.sync.root_resource_id
  path_part   = "sync"
}

resource "aws_api_gateway_method" "sync_post" {
  rest_api_id      = aws_api_gateway_rest_api.sync.id
  resource_id      = aws_api_gateway_resource.sync.id
  http_method      = "POST"
  authorization    = "NONE"
  api_key_required = true
}

resource "aws_api_gateway_integration" "sync_lambda" {
  rest_api_id             = aws_api_gateway_rest_api.sync.id
  resource_id             = aws_api_gateway_resource.sync.id
  http_method             = aws_api_gateway_method.sync_post.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.kb_auto_sync.invoke_arn
}

resource "aws_lambda_permission" "api_gateway" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.kb_auto_sync.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.sync.execution_arn}/*/*"
}

resource "aws_api_gateway_deployment" "sync" {
  rest_api_id = aws_api_gateway_rest_api.sync.id
  depends_on  = [aws_api_gateway_integration.sync_lambda]
  lifecycle { create_before_destroy = true }
}

resource "aws_api_gateway_stage" "prod" {
  deployment_id = aws_api_gateway_deployment.sync.id
  rest_api_id   = aws_api_gateway_rest_api.sync.id
  stage_name    = "prod"
  tags          = { Name = "${var.project_name}-prod-stage" }
}

resource "aws_api_gateway_api_key" "sync" {
  name    = "${var.project_name}-api-key"
  enabled = true
}

resource "aws_api_gateway_usage_plan" "sync" {
  name = "${var.project_name}-sync-plan"

  api_stages {
    api_id = aws_api_gateway_rest_api.sync.id
    stage  = aws_api_gateway_stage.prod.stage_name
  }

  throttle_settings {
    rate_limit  = 10
    burst_limit = 20
  }

  quota_settings {
    limit  = 1000
    period = "DAY"
  }
}

resource "aws_api_gateway_usage_plan_key" "sync" {
  key_id        = aws_api_gateway_api_key.sync.id
  key_type      = "API_KEY"
  usage_plan_id = aws_api_gateway_usage_plan.sync.id
}

# =============================================================================
# MH5: Serverless Scaling (Reserved Concurrency + Async DLQ)
# =============================================================================

resource "aws_lambda_function_event_invoke_config" "kb_sync" {
  function_name          = aws_lambda_function.kb_auto_sync.function_name
  maximum_retry_attempts = 0

  destination_config {
    on_failure {
      destination = aws_sqs_queue.lambda_dlq.arn
    }
  }
}

resource "null_resource" "set_reserved_concurrency" {
  provisioner "local-exec" {
    command = "aws lambda put-function-concurrency --function-name ${aws_lambda_function.kb_auto_sync.function_name} --reserved-concurrent-executions 2 --region ${var.aws_region}"
  }
  triggers   = { lambda_name = aws_lambda_function.kb_auto_sync.function_name }
  depends_on = [aws_lambda_function.kb_auto_sync]
}

resource "aws_sqs_queue" "lambda_dlq" {
  name                      = "${var.project_name}-kb-sync-dlq"
  message_retention_seconds = 1209600
  tags                      = { Name = "${var.project_name}-kb-sync-dlq" }
}
