# Pathgate

A multi-service application: **two single-purpose React frontends**
(one write-only, one read-only), **one shared Python backend**, and
**one database**, deployed the same way — context-path-based routing,
strict tier chain (nginx/router → frontend → backend → db, nobody
skips a tier) — first on a single EC2 instance, then across three
AWS-managed platforms with **no EC2 instance you provision yourself
and no load balancer anywhere**.

```
pathgate-microservices-lab/
├── apps/                        # shared source, built once, deployed every way below
│   ├── backend/                 # FastAPI, storage-backend-agnostic
│   ├── frontend-insert/         # React (Vite) — app1, insert-only, own nginx proxies to backend
│   └── frontend-list/           # React (Vite) — app2, list-only, own nginx proxies to backend
├── architecture diagrams/       # architecture diagrams images
├── docs/                        # architecture diagrams draw.io + the manual EC2 deployment guide
├── v1-docker-compose-ec2/       # ONE EC2 instance, docker-compose, 5 containers, one bridge network
└── v2-serverless-aws/           # same app, no EC2 you provision, no load balancer anywhere
    ├── ecs-fargate/             # ecs-cli compose — Cloud Map instead of an ALB
    ├── elastic-beanstalk/       # eb CLI, Single-Instance env (no ELB) — still 1 EC2, see caveat
    └── lambda/                  # plain aws-cli — CloudFront + API Gateway + Lambda + DynamoDB
```

## The rule being enforced

- `frontend-insert` (**/app1**) only ever calls `POST /api/items`.
- `frontend-list` (**/app2**) only ever calls `GET /api/items`.
- Both call the *same* backend, which is the only thing that ever
  talks to the database.
- **Every request hits the router first.** In v1 and v2's ECS
  Fargate/Elastic Beanstalk, that's nginx, and the chain is literal:
  nginx only talks to a frontend, a frontend only talks to the
  backend, the backend is the only thing that talks to the database.
  v2's Lambda is the one necessary exception — a static S3-hosted
  frontend has no compute to proxy `/api/*` through, so the browser
  calls the backend directly via CloudFront instead. See
  [v2-serverless-aws/lambda/README.md](v2-serverless-aws/lambda/README.md)
  for why that's structural, not a shortcut.

This is enforced by what each frontend's code is capable of calling,
not by a backend permission check — see
[apps/backend/app/main.py](apps/backend/app/main.py) and
[apps/frontend-insert/src/App.jsx](apps/frontend-insert/src/App.jsx).

## Start here

- **[v1-docker-compose-ec2/](v1-docker-compose-ec2)** — run it locally
  in under a minute (`docker compose up --build`). To deploy the same
  five containers to a real EC2 instance by hand instead — IAM role
  for SSM, security group, exact commands — follow
  **[docs/v1-manual-ec2-deployment.md](docs/v1-manual-ec2-deployment.md)**.
- **[v2-serverless-aws/](v2-serverless-aws)** — the same application on
  ECS Fargate, Elastic Beanstalk, and Lambda, each deployed with that
  platform's own CLI (never Terraform), with no EC2 instance
  provisioned directly and no load balancer anywhere — including what
  that constraint costs you (no stable DNS name in front of ECS
  Fargate's entry point, in particular) and the one platform (Elastic
  Beanstalk) where "no EC2" genuinely can't be satisfied, stated
  plainly rather than glossed over.

## Stack

Python (FastAPI), React (Vite), PostgreSQL / DynamoDB, Docker, nginx,
`aws-cli` / `ecs-cli` / `eb` CLI.
