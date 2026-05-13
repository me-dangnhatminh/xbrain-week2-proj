# =============================================================================
# Provider & Data Sources
# =============================================================================

terraform {
  required_version = ">= 1.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# =============================================================================
# S3: Knowledge Base Documents
# =============================================================================

resource "aws_s3_bucket" "knowledge_base" {
  bucket = "${var.project_name}-kb-${var.environment}"

  tags = {
    Name        = "${var.project_name}-kb"
    Environment = var.environment
  }
}

resource "aws_s3_bucket_versioning" "knowledge_base" {
  bucket = aws_s3_bucket.knowledge_base.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "knowledge_base" {
  bucket = aws_s3_bucket.knowledge_base.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

resource "aws_s3_bucket_public_access_block" "knowledge_base" {
  bucket                  = aws_s3_bucket.knowledge_base.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_object" "knowledge_base_docs" {
  for_each = fileset("${path.module}/../backend/data_package/knowledge_base", "*.md")

  bucket       = aws_s3_bucket.knowledge_base.id
  key          = "knowledge_base/${each.value}"
  source       = "${path.module}/../backend/data_package/knowledge_base/${each.value}"
  etag         = filemd5("${path.module}/../backend/data_package/knowledge_base/${each.value}")
  content_type = "text/markdown"
}

# =============================================================================
# DynamoDB: Conversation Memory (L4)
# =============================================================================

resource "aws_dynamodb_table" "conversations" {
  name         = "${var.project_name}-conversations"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "session_id"
  range_key    = "turn_id"

  attribute {
    name = "session_id"
    type = "S"
  }

  attribute {
    name = "turn_id"
    type = "N"
  }

  ttl {
    attribute_name = "expires_at"
    enabled        = true
  }

  tags = {
    Name        = "${var.project_name}-conversations"
    Environment = var.environment
  }
}
