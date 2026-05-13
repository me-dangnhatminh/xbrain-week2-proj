# =============================================================================
# Security Groups
# =============================================================================

# CloudFront managed prefix list (all CF edge IPs)
data "aws_ec2_managed_prefix_list" "cloudfront" {
  name = "com.amazonaws.global.cloudfront.origin-facing"
}

# ALB: accepts HTTP only from CloudFront edge nodes
resource "aws_security_group" "alb" {
  name        = "${var.project_name}-alb-sg-appvpc"
  description = "ALB in App VPC - HTTP from CloudFront only"
  vpc_id      = aws_vpc.app.id

  ingress {
    description     = "HTTP from CloudFront edge"
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    prefix_list_ids = [data.aws_ec2_managed_prefix_list.cloudfront.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project_name}-alb-sg" }
}

# ECS Tasks: accepts traffic from ALB only
resource "aws_security_group" "ecs_task" {
  name        = "${var.project_name}-ecs-task-sg-appvpc"
  description = "ECS Fargate tasks - traffic from ALB"
  vpc_id      = aws_vpc.app.id

  ingress {
    description     = "API from ALB"
    from_port       = 8001
    to_port         = 8001
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  # HTTPS to VPC Endpoints (Bedrock, ECR, SSM, CloudWatch Logs)
  egress {
    description     = "HTTPS to VPC Endpoints"
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    security_groups = [aws_security_group.vpc_endpoints.id]
  }

  # HTTPS to S3/DynamoDB Gateway Endpoints (use prefix lists)
  egress {
    description     = "HTTPS to S3 Gateway Endpoint"
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    prefix_list_ids = [aws_vpc_endpoint.s3.prefix_list_id]
  }

  egress {
    description     = "HTTPS to DynamoDB Gateway Endpoint"
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    prefix_list_ids = [aws_vpc_endpoint.dynamodb.prefix_list_id]
  }

  # NFS to EFS (rule defined separately to avoid cycle)
  egress {
    description = "NFS to EFS"
    from_port   = 2049
    to_port     = 2049
    protocol    = "tcp"
    cidr_blocks = ["10.0.11.0/24", "10.0.12.0/24"]
  }

  # Localhost (monitoring API on port 8000 within same task)
  egress {
    description = "Localhost monitoring API"
    from_port   = 8000
    to_port     = 8000
    protocol    = "tcp"
    cidr_blocks = ["10.0.11.0/24", "10.0.12.0/24"]
  }

  tags = { Name = "${var.project_name}-ecs-task-sg" }
}

# App SG (legacy, kept for flow log evidence)
resource "aws_security_group" "app" {
  name        = "${var.project_name}-app-sg"
  description = "App tier security group"
  vpc_id      = aws_vpc.app.id

  ingress {
    description = "API from Data VPC"
    from_port   = 8001
    to_port     = 8001
    protocol    = "tcp"
    cidr_blocks = ["10.1.0.0/16"]
  }

  ingress {
    description = "ICMP from Data VPC"
    from_port   = -1
    to_port     = -1
    protocol    = "icmp"
    cidr_blocks = ["10.1.0.0/16"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project_name}-app-sg" }
}
