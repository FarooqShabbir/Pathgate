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
├── docs/                        # architecture diagrams + the manual EC2 deployment guide
├── v1-docker-compose-ec2/       # ONE EC2 instance, docker-compose, 5 containers, one bridge network
├── v2-serverless-aws/           # same app, no EC2 you provision, no load balancer anywhere
│   ├── ecs-fargate/             # ecs-cli compose — Cloud Map instead of an ALB
│   ├── elastic-beanstalk/       # eb CLI, Single-Instance env (no ELB) — still 1 EC2, see caveat
│   └── lambda/                  # plain aws-cli — CloudFront + API Gateway + Lambda + DynamoDB
└── v3-eks/                      # same app on a real EKS cluster — Kubernetes-native, EC2
                                  # node group + StatefulSet + Ingress + HPA + Cluster Autoscaler
```

## The rule being enforced

- `frontend-insert` (**/app1**) only ever calls `POST /api/items`.
- `frontend-list` (**/app2**) only ever calls `GET /api/items`.
- Both call the *same* backend, which is the only thing that ever
  talks to the database.
- **Every request hits the router first.** In v1, v2's ECS
  Fargate/Elastic Beanstalk, and v3 (EKS), that's nginx (or an
  Ingress-provisioned ALB standing in for it), and the chain is
  literal: the router only talks to a frontend, a frontend only talks
  to the backend, the backend is the only thing that talks to the
  database. v2's Lambda is the one necessary exception — a static
  S3-hosted frontend has no compute to proxy `/api/*` through, so the
  browser calls the backend directly via CloudFront instead. See
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
- **[v3-eks/](v3-eks)** — the same application on Amazon EKS, built to
  actually exercise Kubernetes' own object model rather than minimize
  it: a real managed node group (not Fargate — `db` needs EBS, which
  Fargate pods can't mount), `db` as a genuine StatefulSet with a
  PersistentVolumeClaim, Ingress + the AWS Load Balancer Controller as
  the router, and HPA paired with Cluster Autoscaler for pod- and
  node-level scaling together. Every `eksctl`/`kubectl`/`aws`/`docker`
  command, typed individually with an explanation, not a script:
  **[docs/v3-eks-manual-deployment.md](docs/v3-eks-manual-deployment.md)**.

## Stack

Python (FastAPI), React (Vite), PostgreSQL / DynamoDB, Docker, nginx,
Kubernetes, `aws-cli` / `ecs-cli` / `eb` CLI / `eksctl` / `kubectl`.

## Status

This repository is source and deployment instructions only. No AWS
infrastructure has been deployed from it — every script in
`v2-serverless-aws/` and every command in `v3-eks/`'s manual guide
makes real, billable AWS API calls only when you actually run it; each
subfolder's README (and, for v3-eks,
[docs/v3-eks-manual-deployment.md](docs/v3-eks-manual-deployment.md))
documents that step explicitly before you do.
