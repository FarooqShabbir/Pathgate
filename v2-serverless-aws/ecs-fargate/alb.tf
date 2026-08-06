# ALB is nginx's replacement here: path-based routing rules stand in
# for nginx's `location` blocks. Unlike nginx, an ALB does NOT rewrite
# or strip the matched path -- it forwards the request untouched --
# which is why the frontend images used in this variant
# (Dockerfile.ecs) serve their own /app1/ and /app2/ prefixes, and the
# backend already mounts everything under /api (see apps/backend).

resource "aws_lb" "main" {
  name               = "${var.project}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.public[*].id
}

resource "aws_lb_target_group" "frontend_insert" {
  name        = "${var.project}-app1-tg"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "ip"
  health_check {
    path = "/app1/"
  }
}

resource "aws_lb_target_group" "frontend_list" {
  name        = "${var.project}-app2-tg"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "ip"
  health_check {
    path = "/app2/"
  }
}

resource "aws_lb_target_group" "backend" {
  name        = "${var.project}-api-tg"
  port        = 8000
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "ip"
  health_check {
    path = "/api/health"
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  # Port 80 in -> port 80 in this listener; everything below is a
  # *path* rule, not a port. Default action = app1 landing page.
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.frontend_insert.arn
  }
}

resource "aws_lb_listener_rule" "app1" {
  listener_arn = aws_lb_listener.http.arn
  priority     = 10
  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.frontend_insert.arn
  }
  condition {
    path_pattern { values = ["/app1", "/app1/*"] }
  }
}

resource "aws_lb_listener_rule" "app2" {
  listener_arn = aws_lb_listener.http.arn
  priority     = 20
  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.frontend_list.arn
  }
  condition {
    path_pattern { values = ["/app2", "/app2/*"] }
  }
}

resource "aws_lb_listener_rule" "api" {
  listener_arn = aws_lb_listener.http.arn
  priority     = 30
  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.backend.arn
  }
  condition {
    path_pattern { values = ["/api/*"] }
  }
}
