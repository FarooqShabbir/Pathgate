output "alb_dns_name" {
  value       = aws_lb.main.dns_name
  description = "Open http://<this>/app1 and http://<this>/app2"
}

output "ecr_backend_url" {
  value = aws_ecr_repository.backend.repository_url
}

output "ecr_frontend_insert_url" {
  value = aws_ecr_repository.frontend_insert.repository_url
}

output "ecr_frontend_list_url" {
  value = aws_ecr_repository.frontend_list.repository_url
}

output "db_endpoint" {
  value = aws_db_instance.main.address
}
