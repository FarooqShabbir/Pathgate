# v2 — ECS Fargate via the AWS ECS CLI (no Terraform, no load balancer, no EC2)

Deployed with the classic **AWS ECS CLI** (`ecs-cli` — a separate
binary from `aws-cli`), not Docker's `docker context create ecs`
integration. That distinction matters here specifically: Docker's
newer ECS integration **always** creates a load balancer for any
compose service with a published port — there's no flag to skip it.
`ecs-cli compose` doesn't have that behavior: Fargate-specific network
settings (subnet, security group, **public IP assignment**) go in a
separate `ecs-params.yml` next to each service's `docker-compose.yml`,
and nothing there requires a target group or load balancer. `nginx`
gets a public IP directly on its task's network interface — that IS
the entry point.

## The shape

Same five pieces as v1, one Fargate task per service (not one task
with five containers — port collisions rule that out: frontend1 and
frontend2 both listen on 3000, so they can't share a task/network
namespace the way `ecs-cli compose` would put them if they were in one
compose file). Cross-service calls use **AWS Cloud Map** private DNS
(`<service>.pathgate.local`) instead of Docker's embedded DNS —
configured per-service in each `ecs-params.yml`, not hand-wired with
separate `aws servicediscovery` calls.

```
Client
  │ :80 → nginx task's OWN public IP (no ALB, no DNS name — see deploy.sh)
  ▼
nginx task ──/app1/*──► frontend1.pathgate.local:3000
  │        ──/app2/*──► frontend2.pathgate.local:3000
  │                            │  own nginx, /api/* proxy
  │                            ▼
  │                     backend.pathgate.local:8000
  │                            │
  │                            ▼
  │                       db.pathgate.local:5432
  └── same tier chain as v1: nginx only reaches frontends,
      frontends only reach backend, backend only reaches db
```

## Prerequisites

- **`ecs-cli`** (the classic Amazon ECS CLI, not `aws-cli`'s built-in
  `aws ecs` subcommands): [install instructions](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/ECS_CLI_installation.html).
  Confirm with `ecs-cli --version`.
- `aws-cli` v2, configured with credentials.
- An existing VPC + one **public** subnet (route to an internet
  gateway, auto-assign-public-IPv4 enabled) — see
  [docs/v1-manual-ec2-deployment.md §4](../../docs/v1-manual-ec2-deployment.md)
  if you need to create one; the same "no default subnet" fix applies
  here.
- Docker, for building the 4 images.

## Deploy

```bash
cd v2-serverless-aws/ecs-fargate

VPC_ID=vpc-xxxx SUBNET_ID=subnet-xxxx ./01-setup-foundation.sh
# security groups (tiered, only sg-nginx open to 0.0.0.0/0), 4 ECR
# repos, task execution role, ECS cluster, `ecs-cli configure`

POSTGRES_PASSWORD='choose-a-strong-password' ./build_push.sh
# builds & pushes the 4 images

./deploy.sh
# deploys db, backend, frontend1, frontend2, nginx in that order via
# `ecs-cli compose service up`, waits for each to stabilize before the
# next, then prints nginx's public IP
```

Open `http://<printed IP>/app1` and `/app2`.

## The trade-off this makes, on purpose

Without a load balancer, there is no stable DNS name in front of
nginx — you're hitting its task's public IP directly, and **that IP
changes** if the task is ever replaced (redeploy, crash, manual
restart). That's the direct, load-bearing consequence of "no load
balancer": an ALB's whole job is normally to give you a stable address
in front of instances/tasks that come and go. Fine for this
comparison; if you need a stable address without reintroducing an
ALB, put a Route 53 record on the task's IP and update it on every
deploy (`deploy.sh` prints the IP precisely so that step could be
scripted next).

## Update / tear down

```bash
POSTGRES_PASSWORD='same password' ./build_push.sh   # rebuild + re-push
./deploy.sh                                          # re-deploys all 5
./teardown.sh                                         # removes everything, including the foundation resources
```

Nothing here has been deployed — every script above makes real,
billable AWS API calls when you actually run it.
