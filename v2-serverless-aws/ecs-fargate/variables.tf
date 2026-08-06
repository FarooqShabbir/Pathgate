variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "project" {
  type    = string
  default = "pathgate"
}

variable "vpc_cidr" {
  type    = string
  default = "10.20.0.0/16"
}

variable "public_subnet_cidrs" {
  type    = list(string)
  default = ["10.20.1.0/24", "10.20.2.0/24"]
}

variable "private_subnet_cidrs" {
  type    = list(string)
  default = ["10.20.11.0/24", "10.20.12.0/24"]
}

variable "db_username" {
  type    = string
  default = "pathgate"
}

variable "db_name" {
  type    = string
  default = "pathgate"
}

variable "container_image_tag" {
  description = "Tag pushed to each ECR repo (see build.sh). Bump per deploy."
  type        = string
  default     = "latest"
}
