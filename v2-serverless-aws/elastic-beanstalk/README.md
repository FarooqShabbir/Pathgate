# v2 — Elastic Beanstalk (Docker platform)

> **Read this first:** Elastic Beanstalk's Docker platform is not
> serverless — it runs your containers on an EC2 Auto Scaling Group
> that *Beanstalk* provisions, not you. Nothing in this Terraform
> config calls `aws_instance`, but EC2 instances will exist in your
> account once you `apply`. If the constraint is "zero EC2 anywhere,"
> use [`ecs-fargate/`](../ecs-fargate) or [`lambda/`](../lambda)
> instead, or swap this environment for **AWS App Runner** (the
> closest EC2-free equivalent). This option is included because it
> was explicitly asked for as one of the three to compare — treat it
> as *"EC2 you don't manage yourself"*, not *"no EC2."*

## Why this variant reuses v1's nginx and frontend images unchanged

Unlike the ALB in the ECS Fargate variant, this deployment puts the
*exact same* nginx from v1 in front of the *exact same* frontend
images (the plain `Dockerfile`, not `Dockerfile.ecs`) — which means it
also inherits v1's strict tiering for free: nginx only ever proxies to
`frontend1`/`frontend2`; each frontend's own nginx is the only thing
that proxies to `backend`; `backend` is the only thing that talks to
the database. Elastic Beanstalk's Docker platform runs `docker compose
up` on a single instance per app server, so the whole v1 topology
comes across with only two changes:

- `image:` (pull from ECR) instead of `build:` (build locally)
- no `db` service — replaced by an external RDS instance

```
Client
  │ :80
  ▼
EB-managed ALB ──► EC2 instance (EB-managed ASG)
                       │  docker compose up
                       ▼
                     nginx :80 ──► frontend1:3000 (/app1/*)
                       │       ──► frontend2:3000 (/app2/*)
                       │            (nginx never talks to backend)
                       │
                frontend1/frontend2's OWN nginx
                       │  proxies /api/* onward
                       ▼
                  backend:8000
                       │
                       ▼
                RDS Postgres :5432
```

## Deploy

```bash
cd v2-serverless-aws/elastic-beanstalk
terraform init
terraform apply           # creates ECR repos, RDS, IAM roles (no environment images yet)
./build_push.sh            # builds & pushes all 4 images
terraform apply            # creates the EB application + environment
```

Open the `environment_url` output, then `/app1` and `/app2`.

Nothing here has been applied — this creates real, billable resources
(EC2 via the ASG, an ALB, RDS). Review `variables.tf` and the caveat
above before running `apply`.
