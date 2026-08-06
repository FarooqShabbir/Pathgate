variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "project" {
  type    = string
  default = "pathgate-eb"
}

variable "db_username" {
  type    = string
  default = "pathgate"
}

variable "db_name" {
  type    = string
  default = "pathgate"
}

variable "instance_type" {
  type    = string
  default = "t3.micro"
}

variable "solution_stack_name" {
  description = "Run `aws elasticbeanstalk list-available-solution-stacks` and pick the current Docker/AL2023 stack -- exact version strings change over time."
  type        = string
  default     = "64bit Amazon Linux 2023 v4.3.0 running Docker"
}
