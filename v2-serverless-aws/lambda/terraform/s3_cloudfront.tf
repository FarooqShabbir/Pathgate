# CloudFront replaces nginx/the ALB as the path router:
#   /app1/*  -> S3 bucket holding frontend-insert's build, under key prefix app1/
#   /app2/*  -> S3 bucket holding frontend-list's build, under key prefix app2/
#   /api/*   -> the HTTP API from apigateway.tf
# Buckets stay private; CloudFront reaches them via Origin Access
# Control, never a public bucket policy.

resource "aws_s3_bucket" "frontend_insert" {
  bucket_prefix = "${var.project}-app1-"
  force_destroy = true
}

resource "aws_s3_bucket" "frontend_list" {
  bucket_prefix = "${var.project}-app2-"
  force_destroy = true
}

resource "aws_cloudfront_origin_access_control" "s3" {
  name                              = "${var.project}-oac"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

data "aws_iam_policy_document" "app1_oac" {
  statement {
    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.frontend_insert.arn}/*"]
    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.main.arn]
    }
  }
}

data "aws_iam_policy_document" "app2_oac" {
  statement {
    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.frontend_list.arn}/*"]
    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.main.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "app1" {
  bucket = aws_s3_bucket.frontend_insert.id
  policy = data.aws_iam_policy_document.app1_oac.json
}

resource "aws_s3_bucket_policy" "app2" {
  bucket = aws_s3_bucket.frontend_list.id
  policy = data.aws_iam_policy_document.app2_oac.json
}

# S3 has no concept of "serve index.html for a directory request" the
# way nginx/`serve` do. This CloudFront Function fills that gap so
# GET /app1/ (no filename) resolves to key app1/index.html.
resource "aws_cloudfront_function" "index_rewrite" {
  name    = "${var.project}-index-rewrite"
  runtime = "cloudfront-js-2.0"
  comment = "Append index.html to directory-style requests"
  publish = true
  code    = <<-EOT
    function handler(event) {
      var request = event.request;
      var uri = request.uri;
      if (uri.endsWith('/')) {
        request.uri += 'index.html';
      } else if (!uri.includes('.')) {
        request.uri += '/index.html';
      }
      return request;
    }
  EOT
}

locals {
  apigw_domain = replace(replace(aws_apigatewayv2_stage.default.invoke_url, "https://", ""), "/", "")
}

resource "aws_cloudfront_distribution" "main" {
  enabled = true

  origin {
    domain_name              = aws_s3_bucket.frontend_insert.bucket_regional_domain_name
    origin_id                = "app1-s3"
    origin_access_control_id = aws_cloudfront_origin_access_control.s3.id
  }

  origin {
    domain_name              = aws_s3_bucket.frontend_list.bucket_regional_domain_name
    origin_id                = "app2-s3"
    origin_access_control_id = aws_cloudfront_origin_access_control.s3.id
  }

  origin {
    domain_name = local.apigw_domain
    origin_id   = "api-gateway"
    custom_origin_config {
      http_port              = 80
      https_port              = 443
      origin_protocol_policy   = "https-only"
      origin_ssl_protocols     = ["TLSv1.2"]
    }
  }

  default_cache_behavior {
    target_origin_id       = "app1-s3"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods         = ["GET", "HEAD"]
    cached_methods           = ["GET", "HEAD"]
    cache_policy_id          = "658327ea-f89d-4fab-a63d-7e88639e58f6" # AWS managed: CachingOptimized
    function_association {
      event_type   = "viewer-request"
      function_arn = aws_cloudfront_function.index_rewrite.arn
    }
  }

  ordered_cache_behavior {
    path_pattern            = "/app1/*"
    target_origin_id        = "app1-s3"
    viewer_protocol_policy  = "redirect-to-https"
    allowed_methods          = ["GET", "HEAD"]
    cached_methods            = ["GET", "HEAD"]
    cache_policy_id           = "658327ea-f89d-4fab-a63d-7e88639e58f6" # CachingOptimized
    function_association {
      event_type   = "viewer-request"
      function_arn = aws_cloudfront_function.index_rewrite.arn
    }
  }

  ordered_cache_behavior {
    path_pattern            = "/app2/*"
    target_origin_id        = "app2-s3"
    viewer_protocol_policy  = "redirect-to-https"
    allowed_methods          = ["GET", "HEAD"]
    cached_methods            = ["GET", "HEAD"]
    cache_policy_id           = "658327ea-f89d-4fab-a63d-7e88639e58f6" # CachingOptimized
    function_association {
      event_type   = "viewer-request"
      function_arn = aws_cloudfront_function.index_rewrite.arn
    }
  }

  ordered_cache_behavior {
    path_pattern             = "/api/*"
    target_origin_id         = "api-gateway"
    viewer_protocol_policy   = "https-only"
    allowed_methods           = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods             = ["GET", "HEAD"]
    cache_policy_id            = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad" # AWS managed: CachingDisabled
    origin_request_policy_id   = "b689b0a8-53d0-40ab-baf2-68738e2966ac" # AWS managed: AllViewerExceptHostHeader
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
