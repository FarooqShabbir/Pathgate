# IMPORTANT CAVEAT -- read before choosing this option
# ------------------------------------------------------
# Elastic Beanstalk's Docker platform is not serverless: under the
# hood it provisions and manages an Auto Scaling Group of EC2
# instances (plus an ALB) on your behalf. Terraform never calls
# `aws_instance` directly here -- EB does that internally the moment
# `aws_elastic_beanstalk_environment` is created -- but EC2 instances
# *will* exist in the account. If "no EC2 instance, anywhere, full
# stop" is a hard requirement, this option does not satisfy it; use
# ecs-fargate/ or lambda/ instead, or replace this environment with
# AWS App Runner, which is the closest EC2-free equivalent to what
# Beanstalk offers. This folder is included because Elastic Beanstalk
# was explicitly requested as one of the three options to evaluate --
# treat it as "managed EC2 you don't provision yourself", not "no EC2".

resource "aws_security_group" "eb_instances" {
  name_prefix = "${var.project}-instances-"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "HTTP (EB's own ALB also sits in front of this, but keep it simple for the lab)"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_iam_role" "eb_ec2" {
  name = "${var.project}-ec2-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "eb_web_tier" {
  role       = aws_iam_role.eb_ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AWSElasticBeanstalkWebTier"
}

resource "aws_iam_role_policy_attachment" "eb_ecr_read" {
  role       = aws_iam_role.eb_ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_instance_profile" "eb_ec2" {
  name = "${var.project}-ec2-profile"
  role = aws_iam_role.eb_ec2.name
}

resource "aws_iam_role" "eb_service" {
  name = "${var.project}-service-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "elasticbeanstalk.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "eb_service_health" {
  role       = aws_iam_role.eb_service.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSElasticBeanstalkEnhancedHealth"
}

resource "aws_iam_role_policy_attachment" "eb_service_managed" {
  role       = aws_iam_role.eb_service.name
  policy_arn = "arn:aws:iam::aws:policy/AWSElasticBeanstalkService"
}

resource "aws_elastic_beanstalk_application" "main" {
  name = var.project
}

resource "aws_elastic_beanstalk_environment" "main" {
  name                = "${var.project}-env"
  application         = aws_elastic_beanstalk_application.main.name
  solution_stack_name = var.solution_stack_name
  tier                = "WebServer"

  setting {
    namespace = "aws:autoscaling:launchconfiguration"
    name      = "IamInstanceProfile"
    value     = aws_iam_instance_profile.eb_ec2.name
  }
  setting {
    namespace = "aws:autoscaling:launchconfiguration"
    name      = "InstanceType"
    value     = var.instance_type
  }
  setting {
    namespace = "aws:autoscaling:launchconfiguration"
    name      = "SecurityGroups"
    value     = aws_security_group.eb_instances.id
  }
  setting {
    namespace = "aws:elasticbeanstalk:environment"
    name      = "ServiceRole"
    value     = aws_iam_role.eb_service.name
  }
  setting {
    namespace = "aws:elasticbeanstalk:environment"
    name      = "EnvironmentType"
    value     = "LoadBalanced"
  }
  setting {
    namespace = "aws:elasticbeanstalk:environment"
    name      = "LoadBalancerType"
    value     = "application"
  }
  setting {
    namespace = "aws:ec2:vpc"
    name      = "VPCId"
    value     = data.aws_vpc.default.id
  }
  setting {
    namespace = "aws:ec2:vpc"
    name      = "Subnets"
    value     = join(",", data.aws_subnets.default.ids)
  }
  setting {
    namespace = "aws:ec2:vpc"
    name      = "ELBSubnets"
    value     = join(",", data.aws_subnets.default.ids)
  }

  # docker-compose.yml's ${VARS}
  setting {
    namespace = "aws:elasticbeanstalk:application:environment"
    name      = "BACKEND_IMAGE"
    value     = "${aws_ecr_repository.backend.repository_url}:latest"
  }
  setting {
    namespace = "aws:elasticbeanstalk:application:environment"
    name      = "FRONTEND_INSERT_IMAGE"
    value     = "${aws_ecr_repository.frontend_insert.repository_url}:latest"
  }
  setting {
    namespace = "aws:elasticbeanstalk:application:environment"
    name      = "FRONTEND_LIST_IMAGE"
    value     = "${aws_ecr_repository.frontend_list.repository_url}:latest"
  }
  setting {
    namespace = "aws:elasticbeanstalk:application:environment"
    name      = "NGINX_IMAGE"
    value     = "${aws_ecr_repository.nginx.repository_url}:latest"
  }
  setting {
    namespace = "aws:elasticbeanstalk:application:environment"
    name      = "DB_HOST"
    value     = aws_db_instance.main.address
  }
  setting {
    namespace = "aws:elasticbeanstalk:application:environment"
    name      = "POSTGRES_DB"
    value     = var.db_name
  }
  setting {
    namespace = "aws:elasticbeanstalk:application:environment"
    name      = "POSTGRES_USER"
    value     = var.db_username
  }
  setting {
    namespace = "aws:elasticbeanstalk:application:environment"
    name      = "POSTGRES_PASSWORD"
    value     = random_password.db.result
  }
}

output "environment_url" {
  value       = aws_elastic_beanstalk_environment.main.endpoint_url
  description = "Open http://<this>/app1 and http://<this>/app2"
}
