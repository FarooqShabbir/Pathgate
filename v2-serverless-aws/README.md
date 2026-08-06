# v2 — the same application, three AWS-managed infrastructures

Full, port-to-port architecture diagrams for each option, with a
step-by-step "what gets called when you hit /app1" trace:
[ECS Fargate](../docs/pathgate-v2-ecs-fargate-architecture.drawio) ·
[Elastic Beanstalk](../docs/pathgate-v2-elastic-beanstalk-architecture.drawio) ·
[Lambda](../docs/pathgate-v2-lambda-architecture.drawio)
(open any of them at [app.diagrams.net](https://app.diagrams.net) →
File → Open From → Device).

Same `apps/` source (one backend, two React frontends), same rule
(app1 = insert-only, app2 = list-only, one shared backend and
database), same routing scheme (`/app1`, `/app2`, `/api`) — three
different ways to run it on AWS without provisioning an EC2 instance
yourself:

| | [`ecs-fargate/`](ecs-fargate) | [`elastic-beanstalk/`](elastic-beanstalk) | [`lambda/`](lambda) |
|---|---|---|---|
| Compute | Fargate tasks (serverless containers) | EC2 Auto Scaling Group, **managed by EB** | Lambda functions |
| Router | Application Load Balancer | EB's ALB → nginx (reused from v1) | CloudFront |
| Database | RDS Postgres | RDS Postgres | DynamoDB |
| "No EC2" constraint | ✅ genuinely none | ⚠️ see the caveat in its README | ✅ genuinely none |
| Frontend serving | Own container per app (nginx, prefix-aware) | Same images as v1, unchanged | S3 (static files) |
| Reaches backend via | ALB routes `/api/*` straight to the backend target group | Each frontend's own nginx proxies `/api/*` to `backend` (same as v1) | CloudFront routes `/api/*` straight to API Gateway |
| IaC | Terraform | Terraform | Terraform |

**Read the Elastic Beanstalk README's caveat before picking it** if
"zero EC2" is a hard requirement — Beanstalk's Docker platform runs on
an EC2 Auto Scaling Group it provisions for you. It's included because
it was one of the three options asked for, but it does not satisfy a
strict no-EC2 constraint the way the other two do.

## What's identical across all three, and why

- The backend's routes are mounted under `/api` (not stripped by any
  proxy in front of it) — see `apps/backend/app/main.py`.
- The storage layer is selected by one environment variable
  (`STORAGE_BACKEND`) — see `apps/backend/app/storage/`.

That's what makes three infrastructures from one codebase practical:
the application code never encodes an assumption about what's routing
to it or what's storing its data.

## What's different, and why it had to be

**v1 and Elastic Beanstalk enforce a strict tier chain**: nginx only
ever talks to the two frontend containers; each frontend's own nginx
is the only thing that talks to `backend`; `backend` is the only thing
that talks to the database. The frontends' `fetch()` calls use a
**relative** path (`api/items`, resolved against `/app1/` or `/app2/`)
specifically so the request stays inside that chain instead of jumping
straight from the gateway to the backend — see
`apps/frontend-*/src/App.jsx` and `apps/frontend-*/nginx.conf`.

**ECS Fargate and Lambda do not (yet) do this.** Their gateways — the
ALB and CloudFront — route `/api/*` directly to the backend target
group / API Gateway, skipping the frontend tier entirely, because
neither an ALB nor CloudFront can proxy application traffic through
another one of your own containers the way nginx can. Giving them the
same strict tiering would mean either ECS Service Connect (so the
frontend containers proxy to `backend`'s internal service-discovery
name) or a Lambda-based edge function in front of the S3 origins — real
extra infrastructure, not a config tweak, and not built yet. Ask if you
want that added.

A second, smaller consequence of no-strip-on-forward (true for the ALB
and CloudFront, not nginx): the ECS Fargate frontends run their own
small nginx that already knows its `/app1/` or `/app2/` prefix
(`Dockerfile.ecs`), because nothing upstream of them strips it first.

**This also means the frontend's `fetch()` target itself has to differ
by deployment**, not just the routing behind it. v1/Beanstalk's
relative `api/items` only works because nginx strips the prefix first
— under an ALB or CloudFront, that same relative call would resolve to
`/app1/api/items`, which matches the `/app1/*` rule (not `/api/*`) and
never reaches the backend at all. `apps/frontend-*/src/App.jsx` reads
this from `import.meta.env.VITE_API_BASE`, defaulting to the relative
path; `Dockerfile.ecs` and `lambda/deploy_frontends.sh` both set
`VITE_API_BASE=/api` at build time to switch it to absolute. Get this
backwards and inserts/lists silently return HTML instead of JSON.

Nothing in this folder has been deployed. Each subfolder's Terraform
creates real, billable AWS resources on `apply` — review the
variables and READMEs first.
