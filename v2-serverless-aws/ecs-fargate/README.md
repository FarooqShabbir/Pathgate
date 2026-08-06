# v2 — ECS Fargate (no EC2)

Same five logical pieces as v1, remapped onto managed AWS services —
**no EC2 instance is created or managed by this stack**; Fargate is
serverless container compute.

| v1 (docker-compose)        | v2 (ECS Fargate)                         |
|-----------------------------|-------------------------------------------|
| nginx container              | Application Load Balancer (path rules)    |
| Docker bridge network        | VPC + security groups                     |
| frontend1 / frontend2 containers | ECS Fargate services (2 tasks)        |
| backend container             | ECS Fargate service (1 task)             |
| Postgres container + volume  | RDS for PostgreSQL (managed, private subnet) |
| `docker-compose up`          | `terraform apply`                         |

## Request flow

```
Client
  │  GET /app1/*          GET /app2/*          GET/POST /api/*
  ▼                        ▼                     ▼
ALB :80  ──────────────────────────────────────────────────
  │  listener rule            listener rule         listener rule
  │  path=/app1*              path=/app2*            path=/api*
  ▼                           ▼                       ▼
frontend-insert task :80   frontend-list task :80   backend task :8000
(nginx serving /app1/*)    (nginx serving /app2/*)  (FastAPI, /api/*)
                                                       │
                                              tasks SG → db SG : 5432
                                                       ▼
                                          RDS Postgres (private subnets)
```

Two important differences from nginx in v1:

1. **No path stripping.** An ALB forwards the matched path unchanged.
   nginx in v1 strips `/app1/` before proxying; the ALB does not. That
   is why the frontend images here are built from `Dockerfile.ecs`
   (not the plain `Dockerfile`) — they run their own tiny nginx that
   already knows to serve itself under `/app1/` or `/app2/`. The
   backend already expects `/api/*` (see `apps/backend/app/main.py`),
   so it needs no change.
2. **No single "everything-in-one-network" bridge.** Each Fargate
   task gets its own elastic network interface in a VPC subnet;
   `security_groups.tf` reproduces the same allow-list nginx's network
   gave you for free: ALB → tasks → RDS, nothing else.

## Deploy

```bash
cd v2-serverless-aws/ecs-fargate
terraform init
terraform apply                 # creates VPC, RDS, ECR repos, empty ECS services
../ecs-fargate/build_push.sh    # builds & pushes the 3 images to ECR
terraform apply                 # re-run so ECS picks up the :latest images
```

Then open `http://<alb_dns_name>/app1` and `/app2` (see the
`alb_dns_name` output).

Nothing in this folder has been applied — running `terraform apply`
will create real, billable AWS resources (ALB, RDS, ECR, CloudWatch
Logs). Review `variables.tf` first.
