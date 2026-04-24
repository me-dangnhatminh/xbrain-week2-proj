# ==========================================
# SECRETS MANAGER (Bảo mật API Keys)
# ==========================================
resource "aws_secretsmanager_secret" "backend_secrets" {
  name_prefix             = "${var.proj_name}-backend-keys-"
  description             = "Chứa toàn bộ API Keys nhạy cảm cho Backend"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "backend_secrets_values" {
  secret_id = aws_secretsmanager_secret.backend_secrets.id
  secret_string = jsonencode({
    MONGODB_URL                       = "mongodb://${var.db_username}:${var.db_password}@${var.db_endpoint}:27017/?tls=true&tlsCAFile=/app/global-bundle.pem&replicaSet=rs0&readPreference=secondaryPreferred&retryWrites=false"
    SECRET_KEY_ACCESS_TOKEN           = var.secret_key_access_token
    SECRET_KEY_REFRESH_TOKEN          = var.secret_key_refresh_token
    STRIPE_SECRET_KEY                 = var.stripe_secret_key
    STRIPE_ENPOINT_WEBHOOK_SECRET_KEY = var.stripe_webhook_secret
    STRIPE_CLI_WEBHOOK_SECRET         = var.stripe_webhook_secret
    EMAIL_USER                        = var.email_user
    EMAIL_PASS                        = var.email_pass
    GOOGLE_CLIENT_ID                  = var.google_client_id
    GOOGLE_CLIENT_SECRET              = var.google_client_secret
    GEMINI_API_KEY                    = var.gemini_api_key
    RESEND_API                        = var.resend_api
  })
}

# ==========================================

resource "aws_ecr_repository" "backend" {
  name                 = "${var.proj_name}-backend"
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecs_cluster" "main" {
  name = "${var.proj_name}-cluster"
}

resource "aws_cloudwatch_log_group" "ecs_logs" {
  name              = "/ecs/${var.proj_name}-backend"
  retention_in_days = 7
}

# IAM Role for ECS Task Execution (Pull image, Push Logs, Get Secrets Manager)
resource "aws_iam_role" "ecs_task_execution_role" {
  name = "${var.proj_name}-ecs-execution-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_task_execution_role_policy" {
  role       = aws_iam_role.ecs_task_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Cho phép ECS Execution Role được lấy chìa khoá từ Secrets Manager
resource "aws_iam_role_policy" "ecs_secrets_access" {
  name = "${var.proj_name}-secrets-access"
  role = aws_iam_role.ecs_task_execution_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action   = ["secretsmanager:GetSecretValue"]
        Effect   = "Allow"
        Resource = [aws_secretsmanager_secret.backend_secrets.arn]
      }
    ]
  })
}

# IAM Role for ECS Task (S3 Access)
resource "aws_iam_role" "app_role" {
  name = "${var.proj_name}-app-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "s3_access" {
  name = "${var.proj_name}-s3-access"
  role = aws_iam_role.app_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:ListBucket"
        ]
        Effect = "Allow"
        Resource = [
          "arn:aws:s3:::${var.s3_bucket}",
          "arn:aws:s3:::${var.s3_bucket}/*"
        ]
      },
      {
        Action = [
          "ssmmessages:CreateControlChannel",
          "ssmmessages:CreateDataChannel",
          "ssmmessages:OpenControlChannel",
          "ssmmessages:OpenDataChannel"
        ]
        Effect   = "Allow"
        Resource = "*"
      }
    ]
  })
}

# Load Balancer and Target Group
resource "aws_lb" "main" {
  name               = "${var.proj_name}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [var.alb_sg_id]
  subnets            = var.public_subnets
}

# Target Group needs target_type = "ip" for Fargate
resource "aws_lb_target_group" "app_tg" {
  name        = "${var.proj_name}-ecs-tg"
  port        = 8080
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  health_check {
    path                = "/health"
    healthy_threshold   = 2
    unhealthy_threshold = 10
    timeout             = 5
    interval            = 30
  }
}

resource "aws_lb_listener" "front_end" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app_tg.arn
  }
}

resource "aws_ecs_task_definition" "backend" {
  family                   = "${var.proj_name}-backend-task"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = 256
  memory                   = 512
  execution_role_arn       = aws_iam_role.ecs_task_execution_role.arn
  task_role_arn            = aws_iam_role.app_role.arn

  container_definitions = jsonencode([
    {
      name      = "backend-container"
      image     = aws_ecr_repository.backend.repository_url
      cpu       = 256
      memory    = 512
      essential = true
      portMappings = [
        {
          containerPort = 8080
          hostPort      = 8080
          protocol      = "tcp"
        }
      ]
      environment = [
        { name = "PORT", value = "8080" },
        { name = "FRONTEND_URL", value = var.cdn_base_url },
        { name = "S3_BUCKET", value = var.s3_bucket },
        { name = "AWS_REGION", value = var.vpc_region },
        { name = "CDN_BASE_URL", value = var.cdn_base_url }
      ]
      secrets = [
        { name = "MONGODB_URL", valueFrom = "${aws_secretsmanager_secret.backend_secrets.arn}:MONGODB_URL::" },
        { name = "SECRET_KEY_ACCESS_TOKEN", valueFrom = "${aws_secretsmanager_secret.backend_secrets.arn}:SECRET_KEY_ACCESS_TOKEN::" },
        { name = "SECRET_KEY_REFRESH_TOKEN", valueFrom = "${aws_secretsmanager_secret.backend_secrets.arn}:SECRET_KEY_REFRESH_TOKEN::" },
        { name = "STRIPE_SECRET_KEY", valueFrom = "${aws_secretsmanager_secret.backend_secrets.arn}:STRIPE_SECRET_KEY::" },
        { name = "STRIPE_ENPOINT_WEBHOOK_SECRET_KEY", valueFrom = "${aws_secretsmanager_secret.backend_secrets.arn}:STRIPE_ENPOINT_WEBHOOK_SECRET_KEY::" },
        { name = "STRIPE_CLI_WEBHOOK_SECRET", valueFrom = "${aws_secretsmanager_secret.backend_secrets.arn}:STRIPE_CLI_WEBHOOK_SECRET::" },
        { name = "EMAIL_USER", valueFrom = "${aws_secretsmanager_secret.backend_secrets.arn}:EMAIL_USER::" },
        { name = "EMAIL_PASS", valueFrom = "${aws_secretsmanager_secret.backend_secrets.arn}:EMAIL_PASS::" },
        { name = "GOOGLE_CLIENT_ID", valueFrom = "${aws_secretsmanager_secret.backend_secrets.arn}:GOOGLE_CLIENT_ID::" },
        { name = "GOOGLE_CLIENT_SECRET", valueFrom = "${aws_secretsmanager_secret.backend_secrets.arn}:GOOGLE_CLIENT_SECRET::" },
        { name = "GEMINI_API_KEY", valueFrom = "${aws_secretsmanager_secret.backend_secrets.arn}:GEMINI_API_KEY::" },
        { name = "RESEND_API", valueFrom = "${aws_secretsmanager_secret.backend_secrets.arn}:RESEND_API::" }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.ecs_logs.name
          "awslogs-region"        = var.vpc_region
          "awslogs-stream-prefix" = "ecs"
        }
      }
    }
  ])
}

resource "aws_ecs_service" "backend_service" {
  name                   = "${var.proj_name}-ecs-service"
  cluster                = aws_ecs_cluster.main.id
  task_definition        = aws_ecs_task_definition.backend.arn
  desired_count          = 2
  launch_type            = "FARGATE"
  enable_execute_command = true

  network_configuration {
    # Su dung Private Subnets va di ra Internet qua NAT Gateway
    subnets          = var.private_subnets
    security_groups  = [var.app_sg_id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.app_tg.arn
    container_name   = "backend-container"
    container_port   = 8080
  }

  depends_on = [aws_lb_listener.front_end]
}

# ==========================================
# API GATEWAY (HTTPS PROXY FOR ALB)
# ==========================================
resource "aws_apigatewayv2_api" "backend_api" {
  name          = "${var.proj_name}-api-gateway"
  protocol_type = "HTTP"
}

resource "aws_apigatewayv2_integration" "alb_integration" {
  api_id             = aws_apigatewayv2_api.backend_api.id
  integration_type   = "HTTP_PROXY"
  integration_uri    = "http://${aws_lb.main.dns_name}/{proxy}"
  integration_method = "ANY"
  connection_type    = "INTERNET"
}

resource "aws_apigatewayv2_route" "default_route" {
  api_id    = aws_apigatewayv2_api.backend_api.id
  route_key = "ANY /{proxy+}"
  target    = "integrations/${aws_apigatewayv2_integration.alb_integration.id}"
}

resource "aws_apigatewayv2_stage" "default_stage" {
  api_id      = aws_apigatewayv2_api.backend_api.id
  name        = "$default"
  auto_deploy = true
}
