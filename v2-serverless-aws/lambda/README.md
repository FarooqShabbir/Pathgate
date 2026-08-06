# v2 — AWS Lambda (fully serverless, no EC2 anywhere)

The only one of the three v2 options with no server, managed or
otherwise, in the request path. Compute is Lambda, routing is
CloudFront, storage is DynamoDB.

| v1 (docker-compose)     | v2 (Lambda)                                   |
|---------------------------|------------------------------------------------|
| nginx container            | CloudFront distribution (path-based behaviors) |
| frontend1 / frontend2 containers | S3 buckets (static build output)         |
| backend container           | Lambda function (FastAPI via Mangum) behind API Gateway HTTP API |
| Postgres container + volume | DynamoDB table                             |
| `docker-compose up`         | `terraform apply`                            |

## Request flow

```
Client
  │  GET /app1/*                 GET /api/*
  ▼                                ▼
CloudFront ─────────────────────────────────────
  │ behavior: /app1/*    │ behavior: /app2/*   │ behavior: /api/*
  ▼                       ▼                     ▼
S3 app1 bucket        S3 app2 bucket        API Gateway (HTTP API)
(key prefix app1/)    (key prefix app2/)         │  route: ANY /api/{proxy+}
                                                    ▼
                                            Lambda (Mangum→FastAPI)
                                                    │
                                                    ▼
                                            DynamoDB table (pathgate-lambda-items)
```

Same two ideas as the other v2 variants, applied to serverless
primitives instead of containers:

- **No path stripping.** CloudFront forwards the matched path as-is,
  same as the ALB. The backend already expects `/api/*`
  (`apps/backend/app/main.py`), so nothing changes there.
- **Directory-index gap.** S3 has no equivalent of nginx's
  `try_files`/`serve`'s implicit `index.html`. A small CloudFront
  Function (`s3_cloudfront.tf`) rewrites `/app1/` → `/app1/index.html`
  at the edge so visiting the bare path works.

## Why DynamoDB here and Postgres everywhere else

A Lambda talking to RDS needs a VPC, a NAT gateway (or VPC endpoints),
and usually RDS Proxy to avoid exhausting connections under concurrent
invocations — three extra moving parts whose only job is making a
stateless function look like a long-lived one. DynamoDB needs none of
that: `apps/backend/app/storage/dynamo_storage.py` talks to it over
the public AWS API, no networking config required. This is a
deliberate trade (SQL/joins for a fully-managed key-value store), not
an oversight — swap in Aurora Serverless v2 + RDS Proxy + VPC
config if strict Postgres parity matters more than simplicity here.

## Deploy

```bash
cd v2-serverless-aws/lambda
./backend/build.sh                 # produce function.zip
cd terraform
terraform init
terraform apply                    # Lambda, API Gateway, DynamoDB, S3, CloudFront
cd ..
./deploy_frontends.sh              # build + upload both React apps, invalidate cache
```

Open `https://<cloudfront_domain>/app1` and `/app2` (see the
`cloudfront_domain` output). CloudFront distributions take several
minutes to reach "Deployed" after the first apply.

Nothing here has been applied — this creates real, billable AWS
resources (Lambda, API Gateway, DynamoDB, S3, CloudFront). Review
`variables.tf` first.
