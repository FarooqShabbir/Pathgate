resource "aws_ecr_repository" "backend" {
  name                 = "${var.project}-backend"
  image_tag_mutability = "MUTABLE"
  force_delete         = true
}

resource "aws_ecr_repository" "frontend_insert" {
  name                 = "${var.project}-frontend-insert"
  image_tag_mutability = "MUTABLE"
  force_delete         = true
}

resource "aws_ecr_repository" "frontend_list" {
  name                 = "${var.project}-frontend-list"
  image_tag_mutability = "MUTABLE"
  force_delete         = true
}
