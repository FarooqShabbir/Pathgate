# v2 — AWS Lambda via plain AWS CLI (no Terraform, no EC2, no load balancer)

Every resource created with a plain `aws <service> create-*` call —
no Terraform, no CloudFormation, no SAM. Compute is Lambda, routing is
CloudFront, storage is DynamoDB. No EC2 instance and no load balancer
anywhere in this stack — CloudFront is a CDN/router, not a load
balancer, and API Gateway is a managed API front door, not one either.

## Where this necessarily deviates from the instructor's flow

The lab's rule is **nginx → frontend → backend → db, nobody skips a
tier** — every other v1/v2 target (EC2, ECS Fargate, Elastic
Beanstalk) keeps that literally true, because they all run the
frontend as a small server (a container with its own nginx) that can
proxy `/api/*` onward to the backend itself.

**A static S3-hosted frontend can't do that** — there's no process
running to proxy anything; it's just files. So here, the browser's own
JavaScript calls the backend *directly* through CloudFront
(`/api/*` → API Gateway → Lambda), the same way it does in every other
variant, but without a frontend-tier hop in between. CloudFront is
still the single front door everything goes through first — matching
"every request comes to the router first" — it just can't forward
`/api/*` through the frontend's own compute the way nginx can, because
there isn't any. This is a structural consequence of choosing a fully
serverless, static-frontend architecture, not a shortcut taken for
convenience — flag it if exact tier-by-tier parity with the other
variants matters more than staying serverless here.

## The shape

```
Client
  │  GET /app1/*             GET /app2/*             /api/*
  ▼                            ▼                        ▼
CloudFront ────────────────────────────────────────────────
  │ behavior /app1/*  │ behavior /app2/*  │ behavior /api/*
  ▼                     ▼                    ▼
S3 app1 bucket      S3 app2 bucket      API Gateway (HTTP API)
(key prefix app1/)  (key prefix app2/)      │ route: ANY /api/{proxy+}
private, OAC only   private, OAC only       ▼
                                        Lambda (Mangum → FastAPI)
                                             │
                                             ▼
                                    DynamoDB (pathgate-lambda-items)
```

## Prerequisites

- `aws-cli` v2, configured with credentials.
- Python 3.12 (for `backend/build.sh`'s `pip install -t`) and `zip`.
- Node + npm (for `deploy_frontends.sh`).

## Deploy

```bash
cd v2-serverless-aws/lambda

./backend/build.sh          # produce function.zip
./01-setup-lambda.sh        # DynamoDB, Lambda execution role, function, API Gateway
./02-setup-cloudfront.sh    # 2 private S3 buckets, OAC, CloudFront function, distribution
./deploy_frontends.sh       # build + upload both React apps, invalidate cache
```

Open `https://<dist_domain>/app1` and `/app2` (both scripts print the
domain; CloudFront distributions take several minutes to reach
"Deployed" after creation, so the first load may lag).

## Why DynamoDB here and Postgres everywhere else

A Lambda talking to RDS needs a VPC, a NAT gateway (or VPC endpoints),
and usually RDS Proxy to avoid exhausting connections under concurrent
invocations — three extra moving parts whose only job is making a
stateless function look like a long-lived one. DynamoDB needs none of
that: `apps/backend/app/storage/dynamo_storage.py` talks to it over
the public AWS API, no networking config required.

## Update / tear down

```bash
./backend/build.sh && ./01-setup-lambda.sh   # rebuild + update the function code
./deploy_frontends.sh                         # re-sync + invalidate frontends
./teardown.sh                                  # removes everything (see its output for the final CloudFront step)
```

Nothing here has been deployed — every script above makes real,
billable AWS API calls when you run it. The CLI shapes used
(`ecs-params.yml`-style precision isn't needed here, but the
CloudFront `DistributionConfig` JSON is genuinely intricate) are based
on documented AWS CLI schemas; if any single call errors on your CLI
version, `aws <service> <command> --generate-cli-skeleton` will show
the exact current shape it expects.
