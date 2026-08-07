# v2 — AWS-managed infrastructure, each platform's own CLI (no Terraform, no EC2, no load balancer)

Full, port-to-port architecture diagrams with a "what gets called when
you hit /app1" trace, one per target:
[ECS Fargate](../docs/pathgate-v2-ecs-fargate-architecture.drawio) ·
[Elastic Beanstalk](../docs/pathgate-v2-elastic-beanstalk-architecture.drawio) ·
[Lambda](../docs/pathgate-v2-lambda-architecture.drawio)
(open at [app.diagrams.net](https://app.diagrams.net) → File → Open
From → Device).

Every resource in this folder is created with a plain CLI tool —
`ecs-cli`, `eb`, or `aws` itself — never Terraform or CloudFormation.
Two hard constraints hold across all three targets: **no EC2 instance
you provision yourself, and no load balancer, anywhere.**

| | [`ecs-fargate/`](ecs-fargate) | [`elastic-beanstalk/`](elastic-beanstalk) | [`lambda/`](lambda) |
|---|---|---|---|
| Tooling | `ecs-cli compose service up` | `eb` CLI | plain `aws` CLI |
| Compute | Fargate tasks | **1 EC2 instance** — see caveat below | Lambda |
| Public entry point | nginx task's own public IP (no ALB) | Elastic IP on the instance (Single-Instance env, no ELB) | CloudFront |
| Database | Postgres container (ephemeral — no EFS wired up) | Postgres container + EBS volume (same as v1, no RDS) | DynamoDB |
| Preserves v1's strict tiering? | ✅ yes — nginx is still the router | ✅ yes — same images as v1 | ⚠️ no frontend tier exists to proxy through — see its README |

## The Elastic Beanstalk caveat, stated plainly

Elastic Beanstalk's Docker platform **cannot run without an EC2
instance** — a Single-Instance environment (used here, see its README)
removes the load balancer and Auto Scaling Group, but Beanstalk still
provisions one EC2 instance to run the containers on. There is no
serverless mode for it. If "zero EC2, no exceptions" is truly
non-negotiable, Elastic Beanstalk is the thing that has to be dropped
from this comparison — not something this folder can route around
while still being Elastic Beanstalk. It's kept here because it was
named as one of the three platforms to demonstrate.

## Why ECS Fargate uses `ecs-cli`, not Docker's `docker context create ecs`

Docker's newer ECS integration is simpler to write against, but it
**always** creates a load balancer for any compose service with a
published port — there's no setting to skip it. The classic AWS ECS
CLI (`ecs-cli compose`) puts Fargate networking (subnet, security
group, **public IP assignment**) in a separate `ecs-params.yml`
instead, and nothing there requires a target group. That's the whole
reason `ecs-fargate/` is structured the way it is — see its README for
the full mechanics (Cloud Map instead of an ALB, one task per service
instead of one task with five containers).

## What "no load balancer" costs you

Every public entry point in this folder is a **bare IP or a Lambda-era
managed front door**, not a stable load-balanced DNS name:

- ECS Fargate: nginx's task gets a public IP that changes if the task
  is ever replaced.
- Elastic Beanstalk: an Elastic IP, which *is* stable, but pinned to
  one instance with no failover if that instance dies.
- Lambda: CloudFront's domain is stable (it's not a load balancer, so
  this constraint doesn't apply there at all) — this is the one
  target where "no load balancer" costs nothing.

This is the direct, expected trade-off of the constraint, not a
mistake — an ALB's whole job is normally absorbing exactly this
problem.

Nothing here has been deployed. Every script in every subfolder makes
real, billable AWS API calls when you actually run it — review each
README first.
