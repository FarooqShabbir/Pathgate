# v2 — Elastic Beanstalk via `eb` CLI (no Terraform, no load balancer)

Same `docker-compose.yml` topology as v1 — nginx does the path routing,
each frontend proxies its own `/api/*` calls to `backend`, `db` is a
plain container with a volume, no RDS. Provisioned with the `eb` CLI
reading this folder directly, not Terraform.

**No load balancer**: the environment is created with
`EnvironmentType: SingleInstance` (also passed as `eb create --single`
below) — an Elastic IP goes straight on the one instance, no ALB in
front of it at all.

> **The EC2 caveat still applies, and can't be removed.** Elastic
> Beanstalk's Docker platform has no serverless mode — `eb create`
> always provisions an EC2 instance to run the containers on (a
> Single-Instance environment still means *one EC2 instance*, just
> without an Auto Scaling Group or ALB in front of it). Nothing here
> calls `aws ec2 run-instances` directly, but Beanstalk does, on your
> behalf, the moment you `eb create`. There is no way to run Elastic
> Beanstalk's Docker platform without this — if "zero EC2, no
> exceptions" is truly non-negotiable, Elastic Beanstalk itself is the
> thing that has to be dropped from the comparison, not just its load
> balancer or Auto Scaling Group. It's kept here because it was
> explicitly named as one of the three platforms to demonstrate; flag
> it if you want it removed instead.

## Prerequisites

- **EB CLI**: `pip install awsebcli` (or `pipx install awsebcli`).
- An AWS CLI profile with credentials.
- Docker, for building the 4 images locally before pushing to ECR.

## Deploy

```bash
cd v2-serverless-aws/elastic-beanstalk

POSTGRES_PASSWORD='choose-a-strong-password' ./build_push.sh
# builds & pushes 4 images, writes .ebextensions/01-environment.config

eb init pathgate-eb-compose --platform docker --region us-east-1
eb create pathgate-eb-compose-env --single
```

`eb create` uploads this folder (`docker-compose.yml` +
`.ebextensions/`) as the application bundle. The generated
`01-environment.config` sets `EnvironmentType: SingleInstance` (no
load balancer) and the four image URIs + DB password as environment
variables *before* Beanstalk ever runs `docker compose up` — so
`${BACKEND_IMAGE}` etc. resolve correctly on the very first deploy,
no separate `eb setenv` step needed.

Open the URL `eb create` prints (or `eb open`), then `/app1` and
`/app2`.

## Update / tear down

```bash
./build_push.sh    # rebuild + re-push if the app code changed
eb deploy          # redeploy with the current .ebextensions + compose file
eb terminate pathgate-eb-compose-env   # tear down when you're done
```

Nothing here has been deployed — `eb create` creates real, billable
AWS resources (one EC2 instance, an Elastic IP, ECR images).
