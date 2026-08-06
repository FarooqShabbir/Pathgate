# Deploying Pathgate v1 across separate EC2 instances (manual, console-first)

No Terraform, no Docker Compose — one container per EC2 instance, wired
together by security groups and private IPs, managed over **AWS
Systems Manager Session Manager (SSM)** instead of SSH — no key pair,
no inbound port 22 anywhere, no public IP required for management on
any instance except the browser-facing one. This is the "take the lab
apart and put it on real, separate boxes" exercise; [v2](../v2-serverless-aws)
is the managed/IaC version of "split across infrastructure."

## 0. What you're building — it's 5 instances, not 4

Two frontends, one backend, one database is four *tiers*, but v1 has a
fifth moving part: **nginx**, the reverse proxy that is the entire
point of the path-based-routing lab. Without its own instance there is
no public entry point and no `/app1` / `/app2` routing — so this guide
uses **five** instances:

| # | Instance | Role | Talks to |
|---|---|---|---|
| 1 | `pathgate-nginx` | Public entry point, path router | frontend1, frontend2 — **nothing else** |
| 2 | `pathgate-frontend1` | React insert app (`/app1`) | backend — **nothing else** |
| 3 | `pathgate-frontend2` | React list app (`/app2`) | backend — **nothing else** |
| 4 | `pathgate-backend` | FastAPI, shared by both frontends | db — **nothing else** |
| 5 | `pathgate-db` | PostgreSQL | (accepts from backend only) |

```
 Internet
    │  :80
    ▼
┌─────────────┐   :3000   ┌──────────────┐   :8000   ┌─────────┐   :5432   ┌────┐
│   nginx     │──────────▶│  frontend1/2 │──────────▶│ backend │──────────▶│ db │
│ (public IP) │           │ (own nginx:  │           │         │           │    │
│             │           │  static+api  │           │         │           │    │
│             │           │  proxy)      │           │         │           │    │
└─────────────┘           └──────────────┘           └─────────┘           └────┘
```

Each arrow above is enforced **twice**: once by which host each
`nginx.conf`/`proxy_pass` points at, and once by security groups that
simply have no rule permitting the skip-a-tier path (nginx → backend
directly is not just unconfigured, it's not *allowed* on the network).

Print or copy this worksheet — you'll fill it in as you go:

| Instance | Instance ID (for SSM) | Public IP (nginx only, for the browser) | Private IP (peer traffic) |
|---|---|---|---|
| nginx | | | |
| frontend1 | | — | |
| frontend2 | | — | |
| backend | | — | |
| db | | — | |

## 1. Prerequisites

- An AWS account with permission to create EC2 instances, IAM roles,
  and security groups (the default VPC is fine — no custom networking
  needed for this lab).
- **AWS CLI v2** installed and configured locally (`aws --version`,
  `aws sts get-caller-identity` to confirm credentials work), plus the
  **Session Manager plugin for the AWS CLI** — this is what lets
  `aws ssm start-session` open a shell; without it the command fails
  with a "SessionManagerPlugin is not found" error. No SSH client and
  no `.pem` key are needed anywhere in this guide.
- The `pathgate-microservices-lab` project pushed to GitHub (simplest
  way to get it onto each instance without SSH — see §7).
- Budget ~$0.25–$1 and a couple of hours: 5× small instances running
  for a few hours costs very little, but see the cleanup step — don't
  leave them running.

## 2. Create an IAM role for SSM access

Console → **IAM → Roles → Create role**
Trusted entity: **AWS service** → **EC2**. Attach the managed policy
**`AmazonSSMManagedInstanceCore`**. Name it `pathgate-ssm-role` →
Create role.

This is what replaces the key pair: every instance gets this role as
its instance profile, the SSM Agent uses it to register itself with
Systems Manager, and `aws ssm start-session` uses it on the other end
to open a shell — over an outbound HTTPS connection the instance
initiates, so nothing needs to be open inbound. Canonical's official
Ubuntu Server AMIs (what this guide uses — see §4) ship the agent
preinstalled and running, same as Amazon Linux.

## 3. Create four security groups

Console → **EC2 → Security Groups → Create security group**, four
times, all in the **same VPC** (the default VPC). **Create them in
this order** — `sg-backend`'s rule below needs `sg-frontend` to
already exist as a pickable source.

**`sg-nginx`**
| Type | Port | Source |
|---|---|---|
| HTTP | 80 | `0.0.0.0/0` |

**`sg-frontend`** (used by *both* frontend1 and frontend2)
| Type | Port | Source |
|---|---|---|
| Custom TCP | 3000 | `sg-nginx` |

**`sg-backend`**
| Type | Port | Source |
|---|---|---|
| Custom TCP | 8000 | `sg-frontend` |

Note there is **no rule here for `sg-nginx`** — that's the whole point.
nginx cannot reach port 8000 on this instance no matter what its
config says.

**`sg-db`**
| Type | Port | Source |
|---|---|---|
| PostgreSQL | 5432 | `sg-backend` |

None of the four groups has an inbound SSH rule, or any other inbound
rule beyond what's listed — management access goes through SSM
(outbound only, handled by the IAM role from §2), not an open port.
Leave outbound rules at the default (allow all) on every group.

## 4. Launch the 5 EC2 instances

### If your default VPC has no subnet

A default VPC normally comes with one default (public) subnet per AZ
already created. If yours doesn't (subnets were deleted at some point,
or the account/region combination never got them), create one by hand
— you only need one subnet for this whole guide, shared by all five
instances:

1. Console → **VPC → Subnets → Create subnet**.
2. VPC: select your **default VPC** (its CIDR is normally
   `172.31.0.0/16`).
3. Availability Zone: any one is fine — e.g. `us-east-1a`.
4. IPv4 CIDR block: a slice of the VPC's range that fits, e.g.
   `172.31.100.0/24`.
5. Create, then select the new subnet → **Actions → Edit subnet
   settings** → enable **"Enable auto-assign public IPv4 address"** →
   Save. (This is off by default even in a default VPC — without it
   none of the five instances get a public IP no matter what you pick
   at launch time.)
6. Confirm it can reach the internet: **VPC → Route Tables**, find the
   one associated with your default VPC (usually named "main"), check
   its routes include `0.0.0.0/0 → igw-...`. Default VPCs almost
   always still have this even with zero subnets; if it's missing, add
   that route with the VPC's internet gateway as the target.

If there's no default VPC at all, the fastest fix is the **VPC →
"Create VPC" → "VPC and more"** wizard — it creates a VPC, public
subnets, an internet gateway, and the routing between them in one step
— then use that instead of "the default VPC" everywhere below.

### Launch the instances

Console → **EC2 → Instances → Launch instances**, five times:

| Name | AMI | Type | Security group | IAM instance profile |
|---|---|---|---|---|
| `pathgate-nginx` | Ubuntu Server 24.04 LTS | t3.micro | `sg-nginx` | `pathgate-ssm-role` |
| `pathgate-frontend1` | Ubuntu Server 24.04 LTS | t3.micro | `sg-frontend` | `pathgate-ssm-role` |
| `pathgate-frontend2` | Ubuntu Server 24.04 LTS | t3.micro | `sg-frontend` | `pathgate-ssm-role` |
| `pathgate-backend` | Ubuntu Server 24.04 LTS | t3.micro | `sg-backend` | `pathgate-ssm-role` |
| `pathgate-db` | Ubuntu Server 24.04 LTS | t3.small | `sg-db` | `pathgate-ssm-role` |

The IAM instance profile field is under **Advanced details** in the
launch wizard — easy to miss. **Skip the "Key pair" step entirely**
(select "Proceed without a key pair") — nothing in this guide uses one.

(`t3.small` for db gives Postgres a bit more headroom; bump any of the
others to `t3.small` too if a `docker build` runs out of memory — 1GB
is occasionally tight for the `npm install` step.)

Under **Network settings**, pick the VPC and subnet from above
explicitly (don't rely on "no preference" if you're not certain it'll
land in a subnet with internet access), and keep **Auto-assign public
IP: Enable**. Every instance still needs *outbound* internet access —
to reach the SSM service, and to `docker build`/`npm install`/`git
clone` — which is what the public IP + that subnet's route to the
internet gateway provides; it's not for inbound SSH anymore. Only
nginx's public IP is something you'll actually use directly, to browse
to it. The security groups from step 3 are what enforce the tiering,
not subnet placement (see §16 for the fully-private,
no-public-IP-at-all hardened version).

Storage: default 20GiB gp3 is plenty for all five.

## 5. Record every instance ID and private IP

Once all five show **Running**: click each instance → copy its
**Instance ID** (`i-0123...`, top of the details panel) and **Private
IPv4 address** into your worksheet from §0. Also grab nginx's
**Public IPv4 address** — that's the only one you'll need directly.
Get them all now to avoid re-checking mid-guide.

## 6. Confirm SSM connectivity, then install Docker on all 5 instances

First confirm every instance registered with Systems Manager: Console
→ **Systems Manager → Fleet Manager** (or **Node Management →
Session Manager**) — all five should show as **Managed** within a
minute or two of launching. If one doesn't, re-check its IAM instance
profile from §4.

Then, for each instance, open a shell and install Docker:

```bash
aws ssm start-session --target <instance-id>
```

```bash
sudo apt-get update -y
sudo apt-get install -y docker.io git gettext-base
sudo systemctl enable --now docker
sudo usermod -aG docker ssm-user
exit
```

Start a new session (`aws ssm start-session --target <instance-id>`
again) for the group membership to take effect — SSM sessions land you
as `ssm-user` on Ubuntu the same as on any other supported OS, which
is why the `usermod` line targets `ssm-user`, not `ubuntu` (Ubuntu's
normal default login user, unused here since nothing SSHes in).
`gettext-base` is Ubuntu's package for `envsubst`, used in §10/§11/§12
— installing it everywhere is harmless and one less thing to remember
later. (`docker.io` is the distro-maintained Docker Engine package —
fine for this lab; if you need a newer Docker version, use the
official `download.docker.com` apt repo instead.)

## 7. Get the code onto each instance

In each SSM session, on **all five** instances (each only needs its
own subfolder, but cloning the whole repo is simplest):

```bash
git clone https://github.com/<you>/pathgate-microservices-lab.git ~/pathgate
```

No GitHub account to push to? The only alternative without SSH is via
S3: `aws s3 cp` a zip of the project from your machine to a bucket,
then `aws s3 cp s3://<bucket>/pathgate.zip .` from inside each SSM
session and unzip it — that needs the `pathgate-ssm-role` from §2 to
also have S3 read access (attach `AmazonS3ReadOnlyAccess`, or a
bucket-scoped policy, for this one extra step). GitHub is simpler and
is what the rest of this guide assumes.

## 8. `pathgate-db` — run PostgreSQL

Connect: `aws ssm start-session --target <db instance ID>`.

```bash
docker volume create db_data
docker run -d --name pathgate-db --restart unless-stopped \
  -e POSTGRES_USER=pathgate \
  -e POSTGRES_PASSWORD='choose-a-strong-password' \
  -e POSTGRES_DB=pathgate \
  -p 5432:5432 \
  -v db_data:/var/lib/postgresql/data \
  postgres:16-alpine
```

Verify: `docker ps` shows it `Up`; `docker logs pathgate-db --tail 5`
ends with `database system is ready to accept connections`.

Write down the password — the backend needs the identical value next.

## 9. `pathgate-backend` — build and run FastAPI

Connect: `aws ssm start-session --target <backend instance ID>`.

```bash
cd ~/pathgate/apps/backend
docker build -t pathgate-backend .
docker run -d --name pathgate-backend --restart unless-stopped \
  -e STORAGE_BACKEND=postgres \
  -e DB_HOST=<db instance PRIVATE IP> \
  -e DB_PORT=5432 \
  -e POSTGRES_DB=pathgate \
  -e POSTGRES_USER=pathgate \
  -e POSTGRES_PASSWORD='same password as step 8' \
  -p 8000:8000 \
  pathgate-backend
```

Verify **from this same instance**:
```bash
curl http://localhost:8000/api/health
# {"status":"ok"}
```
If this hangs or errors: check `sg-db` allows `5432` from `sg-backend`,
and that `DB_HOST` is the *private* IP, not the public one.

## 10. `pathgate-frontend1` — build and run App 1 (insert)

Connect: `aws ssm start-session --target <frontend1 instance ID>`.

```bash
cd ~/pathgate
BACKEND_IP=<backend instance PRIVATE IP> \
  bash v1-docker-compose-ec2/distributed-ec2/render-frontend-nginx.sh apps/frontend-insert

cd apps/frontend-insert
docker build -t pathgate-frontend-insert .
docker run -d --name pathgate-frontend-insert --restart unless-stopped \
  -p 3000:3000 \
  pathgate-frontend-insert
```

The `render-frontend-nginx.sh` step rewrites this app's own
`nginx.conf` so its `/api/` proxy points at the backend's *private
IP* instead of the Docker Compose service name `backend` (which only
resolves inside a shared bridge network — there isn't one here).

Verify from this instance:
```bash
curl http://localhost:3000/                      # returns HTML
curl -X POST http://localhost:3000/api/items \
  -H "Content-Type: application/json" \
  -d '{"title":"test from frontend1"}'            # returns the created row as JSON
```
That second command is a full round trip through *this* instance to
backend to db — worth confirming before nginx is even up, so you know
which tier to blame if something's wrong later.

## 11. `pathgate-frontend2` — build and run App 2 (list)

Connect: `aws ssm start-session --target <frontend2 instance ID>`.
Same pattern, pointed at `frontend-list`:

```bash
cd ~/pathgate
BACKEND_IP=<backend instance PRIVATE IP> \
  bash v1-docker-compose-ec2/distributed-ec2/render-frontend-nginx.sh apps/frontend-list

cd apps/frontend-list
docker build -t pathgate-frontend-list .
docker run -d --name pathgate-frontend-list --restart unless-stopped \
  -p 3000:3000 \
  pathgate-frontend-list
```

Verify:
```bash
curl http://localhost:3000/api/items
```
Should return a JSON array containing the "test from frontend1" row —
proof both frontends really do share one backend and one database.

## 12. `pathgate-nginx` — build and run the gateway

Connect: `aws ssm start-session --target <nginx instance ID>`.

```bash
cd ~/pathgate
FRONTEND1_IP=<frontend1 instance PRIVATE IP> \
FRONTEND2_IP=<frontend2 instance PRIVATE IP> \
  bash v1-docker-compose-ec2/distributed-ec2/render-gateway-nginx.sh v1-docker-compose-ec2/nginx

cd v1-docker-compose-ec2/nginx
docker build -t pathgate-nginx .
docker run -d --name pathgate-nginx --restart unless-stopped \
  -p 80:80 \
  pathgate-nginx
```

## 13. Verify from your own machine

Open in a browser (or `curl`):
- `http://<nginx instance PUBLIC IP>/app1` — insert form
- `http://<nginx instance PUBLIC IP>/app2` — list table, should
  already show the row you inserted with `curl` in step 10

If both load and the row shows up on `/app2`, all five instances and
every hop between them are wired correctly.

## 14. Troubleshooting — test one hop at a time

- **Instance not "Managed" in Session Manager / `start-session` fails
  with "TargetNotConnected"**: its IAM instance profile isn't
  `pathgate-ssm-role`, or it has no outbound internet route yet (check
  it's in a subnet with a route to the internet gateway and got a
  public IP — see §4 if you built the subnet by hand). Give it a
  minute or two after launch — the SSM Agent needs to phone home once
  before it appears as Managed. If it still doesn't, the agent may not
  be preinstalled on whichever Ubuntu AMI you picked (some minimal or
  third-party listings omit it) — Canonical's official "Ubuntu Server"
  AMIs always include it; if you used a different one, you'd need
  console/EC2 Instance Connect access to install it manually, which
  defeats the point of this section — relaunch with the official AMI.
- **`start-session` fails locally with "SessionManagerPlugin is not
  found"**: the plugin from §1 isn't installed, or isn't on `PATH`.
- **502/504 from nginx**: frontend instance isn't reachable. Check
  `sg-frontend` allows `3000` from `sg-nginx`, and confirm the IP
  actually baked into the config: `grep proxy_pass ~/pathgate/v1-docker-compose-ec2/nginx/nginx.conf` (in an SSM session on the nginx instance).
- **Page loads, insert/list fails**: same idea one tier down. Check
  `sg-backend` allows `8000` from `sg-frontend`, and
  `grep proxy_pass ~/pathgate/apps/frontend-insert/nginx.conf` (on that
  frontend instance) to confirm the backend's IP is correct.
- **Backend healthy but writes fail**: check `sg-db` allows `5432`
  from `sg-backend`, and that the password in `docker run` for backend
  matches the one used to launch `pathgate-db` exactly.
- **Container missing from `docker ps`**: `docker logs <name>` for the
  crash reason — usually a typo'd env var or a port already bound.
- General rule: `curl` from each instance to the *next* instance's
  private IP before assuming a problem is further away — the same
  logic as the verify steps in §9–§11.

## 15. Cost and cleanup

Five small instances for a couple of hours costs a small fraction of a
dollar, but **don't leave them running**:

Console → **EC2 → Instances** → select all five → **Instance state →
Terminate**. Afterward, **EC2 → Security Groups**, delete the four you
created (only possible once nothing references them), and **IAM →
Roles**, delete `pathgate-ssm-role` (only possible once nothing uses
it — it's an instance profile, not attached to your own IAM identity,
so this is safe to remove any time after the instances are gone).

## 16. Optional hardening (not required for this lab)

- **Go fully private**: move all five instances into a **private
  subnet** with no public IP at all — SSM works there too, but only if
  the VPC has interface endpoints for `com.amazonaws.<region>.ssm`,
  `ssmmessages`, and `ec2messages` (without them, the agent has no way
  to reach the SSM service). Put nginx behind an internet-facing ALB
  instead of giving it a public IP directly — the closest hand-rolled
  approximation of what [v2's ECS Fargate](../v2-serverless-aws/ecs-fargate)
  does with Terraform.
- Replace the "private IP baked into `nginx.conf` at build time"
  approach with a small **private Route 53 hosted zone**, so replacing
  an instance doesn't require re-rendering and rebuilding every config
  that pointed at its old IP.
- Move `POSTGRES_PASSWORD` out of a literal `docker run` flag into
  **AWS Secrets Manager**, fetched at container start — exactly what
  [v2's ECS Fargate Terraform](../v2-serverless-aws/ecs-fargate/rds.tf)
  already does for the managed version of this same idea.
- Scope `pathgate-ssm-role` down further with **Session Manager
  logging** (CloudWatch Logs or S3) enabled on the SSM preferences, so
  every command run in every session is auditable — worth doing before
  this pattern is used for anything beyond a lab.
