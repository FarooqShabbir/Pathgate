resource "aws_ecr_repository" "backend" {
  name         = "${var.project}-backend"
  force_delete = true
}
resource "aws_ecr_repository" "frontend_insert" {
  name         = "${var.project}-frontend-insert"
  force_delete = true
}
resource "aws_ecr_repository" "frontend_list" {
  name         = "${var.project}-frontend-list"
  force_delete = true
}
resource "aws_ecr_repository" "nginx" {
  name         = "${var.project}-nginx"
  force_delete = true
}
