# Pathgate

A multi-service application: **two single-purpose React frontends**
(one write-only, one read-only), **one shared Python backend**, and
**one database**, deployed the same way across five different
infrastructures — a local/EC2 Docker Compose stack, ECS Fargate,
Elastic Beanstalk, and AWS Lambda with context path based routing.

```
pathgate-microservices-lab/
├── apps/                        # shared source, built once, deployed five ways
│   ├── backend/                 # FastAPI, storage-backend-agnostic
│   ├── frontend-insert/         # React (Vite) — app1, insert-only, own nginx proxies to backend
│   └── frontend-list/           # React (Vite) — app2, list-only, own nginx proxies to backend
├── docs/                        # architecture diagrams (v1 + all 3 v2 options) + the manual multi-EC2 guide
├── v1-docker-compose-ec2/       # local Docker host, single bridge network
│   └── distributed-ec2/         # nginx.conf templates for the 5-instance manual deploy
└── v2-serverless-aws/           # same app, no EC2 instances created directly
    ├── ecs-fargate/
    ├── elastic-beanstalk/       # (managed EC2 under the hood — see its README)
    └── lambda/
```

## The rule being enforced

- `frontend-insert` (**/app1**) only ever calls `POST /api/items`.
- `frontend-list` (**/app2**) only ever calls `GET /api/items`.
- Both call the *same* backend, which is the only thing that ever
  talks to the database.

This is enforced by what each frontend's code is capable of calling,
not by a backend permission check — see [v2's
README](v2-serverless-aws/README.md#what-s-identical-across-all-three-and-why)
for how the same backend and routing convention hold across every
deployment.

## Start here

- **[v1-docker-compose-ec2/](v1-docker-compose-ec2)** — run it locally
  in under a minute (`docker compose up --build`). To split the same
  five containers across five separate EC2 instances by hand, follow
  **[docs/v1-manual-ec2-deployment.md](docs/v1-manual-ec2-deployment.md)**.
- **[v2-serverless-aws/](v2-serverless-aws)** — the same application
  re-deployed on ECS Fargate, Elastic Beanstalk, and Lambda, with a
  comparison table and an explanation of what had to change (and why)
  moving from nginx to an ALB/CloudFront.

## Stack

Python (FastAPI), React (Vite), PostgreSQL / DynamoDB, Docker,
Terraform, nginx.

## Status

This repository is source and infrastructure-as-code only. No AWS
infrastructure has been deployed from it — every `terraform apply` in
`v2-serverless-aws/` is a deliberate, separate step documented in each
subfolder's README.
