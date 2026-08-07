# Deploying Pathgate v1 on one EC2 instance (manual, console-first)

One EC2 instance, one `docker compose up`, five containers — the
exact same [`docker-compose.yml`](../v1-docker-compose-ec2/docker-compose.yml)
you'd run locally, just on a real box instead of your laptop. Managed
over **AWS Systems Manager Session Manager (SSM)** instead of SSH — no
key pair, no inbound port 22 anywhere.

## 0. What you're deploying

```
 Internet
    │  :80
    ▼
┌─────────────────────────────────────────────────────────┐
│  ONE EC2 instance                                         │
│                                                             │
│  docker compose up  →  5 containers, 1 bridge network      │
│                                                             │
│   nginx :80 ──► frontend1:3000 ──┐                         │
│      │      ──► frontend2:3000 ──┼──► backend:8000 ──► db:5432
│      │                            │      (own nginx        (Postgres,
│      │                            │       proxies /api)     volume)
│      └── only nginx has a host port mapping (80:80)        │
└─────────────────────────────────────────────────────────┘
```

Same strict tier chain as running it locally: nginx only talks to the
two frontend containers, each frontend's own nginx is the only thing
that talks to `backend`, `backend` is the only thing that talks to
`db`. Nothing here is different from `docker-compose.yml` itself —
this guide is entirely about getting *an EC2 instance* to the point
where `docker compose up --build` can run on it.

## 1. Prerequisites

- An AWS account with permission to create an EC2 instance, an IAM
  role, and a security group (the default VPC is fine).
- **AWS CLI v2**, configured (`aws sts get-caller-identity` to
  confirm), plus the **Session Manager plugin for the AWS CLI** — this
  is what lets `aws ssm start-session` open a shell. No SSH client and
  no `.pem` key are needed anywhere in this guide.
- The `pathgate-microservices-lab` project pushed to GitHub (simplest
  way to get it onto the instance without SSH — see §7).

## 2. Create an IAM role for SSM access

Console → **IAM → Roles → Create role** → Trusted entity: **AWS
service** → **EC2** → attach the managed policy
**`AmazonSSMManagedInstanceCore`** → name it `pathgate-ssm-role`.

This replaces a key pair entirely: the SSM Agent (preinstalled on
Canonical's official Ubuntu Server AMIs) uses this role to register
the instance with Systems Manager, over an outbound HTTPS connection
it initiates — nothing needs to be open inbound for management.

## 3. Create one security group

Console → **EC2 → Security Groups → Create security group**, in your
VPC:

| Type | Port | Source |
|---|---|---|
| HTTP | 80 | `0.0.0.0/0` |

That's the only rule needed. Every other container (frontend1,
frontend2, backend, db) is reachable only from inside the same
Docker bridge network on this one instance — there's no second
instance for a security group to gate traffic between, and no inbound
SSH rule anywhere (SSM handles management access outbound-only, same
reasoning as the IAM role above).

## 4. Launch the EC2 instance

### If your default VPC has no subnet

A default VPC normally has one subnet per AZ already. If yours
doesn't:

1. Console → **VPC → Subnets → Create subnet** → your default VPC →
   pick an AZ → a CIDR slice that fits, e.g. `172.31.100.0/24`.
2. Select it → **Actions → Edit subnet settings** → enable **"Enable
   auto-assign public IPv4 address"** (off by default even here).
3. Confirm **VPC → Route Tables** shows `0.0.0.0/0 → igw-...` on the
   table associated with that subnet; default VPCs almost always keep
   this even with zero subnets.

If there's no default VPC at all, **VPC → Create VPC → "VPC and
more"** creates one with public subnets and the routing already done.

### Launch it

Console → **EC2 → Instances → Launch instances**:

| Setting | Value |
|---|---|
| Name | `pathgate-v1` |
| AMI | Ubuntu Server 24.04 LTS |
| Instance type | `t3.small` (four builds run concurrently on `docker compose up --build`; `t3.micro`'s 1GB RAM is tight for that, though workable if you build one image at a time) |
| Key pair | **Proceed without a key pair** — nothing here uses one |
| Network | the subnet from above, **Auto-assign public IP: Enable** |
| Security group | the one from §3 |
| IAM instance profile | `pathgate-ssm-role` (under **Advanced details** — easy to miss) |
| Storage | 20 GiB gp3 |

## 5. Confirm SSM connectivity, then install Docker

Console → **Systems Manager → Fleet Manager** (or **Node Management →
Session Manager**) — the instance should show as **Managed** within a
minute or two. If it doesn't, re-check the IAM instance profile from
§4.

```bash
aws ssm start-session --target <instance-id>
```

```bash
sudo apt-get update -y
sudo apt-get install -y ca-certificates curl gnupg git

# Ubuntu's own "docker.io" package does NOT carry the Compose v2
# plugin at all -- docker-compose-plugin only exists in Docker's own
# apt repo (download.docker.com), so it has to be added first.
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt-get update -y
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo systemctl enable --now docker
sudo usermod -aG docker ssm-user
exit
```

Start a new session for the group membership to take effect. SSM
sessions land you as `ssm-user` regardless of Ubuntu's normal default
login user (`ubuntu`, unused here since nothing SSHes in).
`docker-ce` here is Docker Inc.'s own Engine build (not Ubuntu's older
`docker.io`), and `docker-compose-plugin` is what makes `docker
compose` (the modern plugin form, not the standalone `docker-compose`
binary) available at all.

## 6. Get the code onto the instance and run it

```bash
git clone https://github.com/<you>/pathgate-microservices-lab.git ~/pathgate
cd ~/pathgate/v1-docker-compose-ec2
cp .env.example .env
nano .env   # set a real POSTGRES_PASSWORD

docker compose up --build -d
docker compose ps   # all 5 should show Up
```

No GitHub account to push to? `aws s3 cp` a zip of the project to a
bucket from your machine, then `aws s3 cp s3://<bucket>/pathgate.zip .`
from inside the SSM session and unzip it — needs the
`pathgate-ssm-role` from §2 to also have S3 read access
(`AmazonS3ReadOnlyAccess`, or a bucket-scoped policy) for this one
extra step. GitHub is simpler and is what the rest of this guide
assumes.

## 7. Verify from your own machine

Console → **EC2 → Instances** → copy the instance's **Public IPv4
address**. Open in a browser:

- `http://<public IP>/app1` — insert form
- `http://<public IP>/app2` — list table

If both load and a row inserted on `/app1` shows up on `/app2`, all
five containers and every hop between them are wired correctly.

## 8. Troubleshooting

- **Instance not "Managed" in Session Manager**: its IAM instance
  profile isn't `pathgate-ssm-role`, or it has no outbound internet
  route yet (check the subnet's route table and that it got a public
  IP). Give it a minute or two after launch.
- **`start-session` fails locally with "SessionManagerPlugin is not
  found"**: the plugin from §1 isn't installed or isn't on `PATH`.
- **Nothing loads on port 80**: `docker compose ps` — is `nginx`
  `Up`? `docker compose logs nginx`. Then check the security group
  from §3 actually has the port-80-from-`0.0.0.0/0` rule.
- **Page loads, insert/list fails**: `docker compose logs backend`
  and `docker compose logs db` — most often a `POSTGRES_PASSWORD`
  mismatch between what's in `.env` and what the `db` container
  started with (Postgres only reads the password on its *first* boot
  with an empty data volume — if you changed `.env` after the first
  `up`, `docker compose down -v` and `up` again to reset it).
- **`docker compose up --build` runs out of memory**: relaunch as
  `t3.small`/`t3.medium`, or build one service at a time with
  `docker compose build backend` etc. before `docker compose up -d`.

## 9. Cost and cleanup

A `t3.small` for a few hours costs a small fraction of a dollar, but
**don't leave it running**:

Console → **EC2 → Instances** → select it → **Instance state →
Terminate**. Then **EC2 → Security Groups**, delete the one you
created, and **IAM → Roles**, delete `pathgate-ssm-role` (both only
possible once the instance is gone).

## 10. Optional hardening (not required for this lab)

- **Go fully private**: move the instance into a private subnet with
  no public IP, put it behind an internet-facing ALB instead — SSM
  still works there too, but only if the VPC has interface endpoints
  for `com.amazonaws.<region>.ssm`, `ssmmessages`, and `ec2messages`.
- Move `POSTGRES_PASSWORD` out of the `.env` file into **AWS Secrets
  Manager**, fetched at container start instead of committed to a
  plaintext file on the instance.
- Put the `db_data` Docker volume on a separate, snapshotted EBS
  volume instead of the root volume, so instance replacement doesn't
  risk the data.
- Enable **Session Manager logging** (CloudWatch Logs or S3) in SSM
  preferences so every command run in every session is auditable.
