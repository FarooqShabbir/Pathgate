output "cloudfront_domain" {
  value       = aws_cloudfront_distribution.main.domain_name
  description = "Open https://<this>/app1 and /app2"
}

output "cloudfront_distribution_id" {
  value = aws_cloudfront_distribution.main.id
}

output "frontend_insert_bucket" {
  value = aws_s3_bucket.frontend_insert.bucket
}

output "frontend_list_bucket" {
  value = aws_s3_bucket.frontend_list.bucket
}

output "api_invoke_url" {
  value = aws_apigatewayv2_stage.default.invoke_url
}
