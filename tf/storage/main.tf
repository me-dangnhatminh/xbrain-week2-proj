resource "aws_s3_bucket" "s3_assets" {
  bucket_prefix = "${var.proj_name}-assets-"
}

resource "aws_s3_bucket_public_access_block" "public_access" {
  bucket = aws_s3_bucket.s3_assets.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_cloudfront_origin_access_control" "oac" {
  name                              = "${var.proj_name}-oac"
  description                       = "OAC for ${var.proj_name} S3 Bucket"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_distribution" "s3_distribution" {
  origin {
    domain_name              = aws_s3_bucket.s3_assets.bucket_regional_domain_name
    origin_access_control_id = aws_cloudfront_origin_access_control.oac.id
    origin_id                = "S3-${var.proj_name}-assets"
  }

  enabled             = true
  is_ipv6_enabled     = true
  default_root_object = "index.html"

  default_cache_behavior {
    allowed_methods  = ["GET", "HEAD", "OPTIONS"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = "S3-${var.proj_name}-assets"

    forwarded_values {
      query_string = false
      cookies {
        forward = "none"
      }
    }

    viewer_protocol_policy = "redirect-to-https"
    min_ttl                = 0
    default_ttl            = 3600
    max_ttl                = 86400
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }
}

resource "aws_s3_bucket_policy" "assets_policy" {
  bucket = aws_s3_bucket.s3_assets.id

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Sid    = "AllowCloudFrontServicePrincipal",
        Effect = "Allow",
        Principal = {
          Service = "cloudfront.amazonaws.com"
        },
        Action   = "s3:GetObject",
        Resource = "${aws_s3_bucket.s3_assets.arn}/*",
        Condition = {
          StringEquals = {
            "AWS:SourceArn" = aws_cloudfront_distribution.s3_distribution.arn
          }
        }
      }
    ]
  })

  depends_on = [aws_s3_bucket_public_access_block.public_access]
}

resource "aws_s3_object" "frontend_assets" {
  for_each = fileset("${path.module}/../../5XRestaurant/client/dist", "**/*")

  bucket = aws_s3_bucket.s3_assets.id
  key    = each.value
  source = "${path.module}/../../5XRestaurant/client/dist/${each.value}"
  etag   = filemd5("${path.module}/../../5XRestaurant/client/dist/${each.value}")
  content_type = lookup(
    {
      "html" = "text/html"
      "css"  = "text/css"
      "js"   = "application/javascript"
      "png"  = "image/png"
      "svg"  = "image/svg+xml"
      "json" = "application/json"
    },
    element(split(".", each.value), length(split(".", each.value)) - 1),
    "application/octet-stream"
  )
}
