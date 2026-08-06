# v1 — Docker Compose lab (single Docker host / EC2)

Five containers, one bridge network, path-based routing through nginx.
Editable architecture diagram: [docs/pathgate-v1-architecture.drawio](../docs/pathgate-v1-architecture.drawio)
(open at [app.diagrams.net](https://app.diagrams.net) → File → Open From → Device).

```
                          host port 80
                               │
                       ┌───────▼────────┐
     GET /app1/*  ───► │      nginx      │ ◄─── GET /app2/*
                       │  (reverse proxy) │
                       └───┬─────────┬───┘
                       app-network (bridge)
              ┌────────────┘         └────────────┐
              ▼                                    ▼
     frontend1:3000                        frontend2:3000
     (insert form +                        (list table +
      own nginx, proxies                    own nginx, proxies
      /api/* → backend)                     /api/* → backend)
              │                                    │
              └─────────────┬──────────────────────┘
                             ▼
                       backend:8000 (FastAPI)
                             │
                             ▼
                       db:5432 (Postgres)
                       volume: db_data
```

Strict tiering, enforced by config (and, in the [EC2 guide](../docs/v1-manual-ec2-deployment.md),
by security groups too): **nginx only ever talks to the two frontends.
Each frontend only ever talks to backend. Backend is the only thing
that talks to db.** nginx's config has no idea `backend` or `db`
exist — see `nginx/nginx.conf` and `apps/frontend-insert/nginx.conf`.

## Run it

```bash
cp .env.example .env   # edit POSTGRES_PASSWORD
docker compose up --build
```

Then open:
- `http://localhost/app1` — insert form (POST only)
- `http://localhost/app2` — list table (GET only)

Only `nginx` publishes a host port (`80:80`). Every other container is
reachable solely by its service name over `app-network`. `nginx.conf`
only ever mentions `frontend1:3000` and `frontend2:3000` — DNS names
doubling as the "port-to-port" wiring, resolved by Docker's embedded
DNS on the bridge network.

## Why two requests, both staying inside the chain

Loading `/app1` is two separate flows, and **neither one skips a
tier**:

1. **Page load** (browser → nginx → frontend1): nginx strips `/app1/`
   and forwards to `frontend1:3000`, whose own nginx serves the
   compiled React app's HTML/JS/CSS from its `location /`. Backend and
   db are not touched yet.
2. **Form submit** (browser → nginx → frontend1 → backend → db): the
   React code *running in the browser* calls `fetch('api/items')` — a
   path **relative** to `/app1/`, so it becomes `/app1/api/items`.
   nginx strips `/app1/` the same way as any other request and
   forwards `/api/items` to `frontend1:3000`. That container's own
   nginx (`apps/frontend-insert/nginx.conf`) has a second `location
   /api/` block that proxies it onward to `backend:8000/api/items`,
   which writes to `db:5432`.

The top-level nginx's config file has no `backend` or `db` in it
anywhere — it cannot reach either one even if you tried, because
nothing ever configures that route. Each frontend container is a
small reverse proxy in its own right, not just a static file host.

## Splitting this across separate EC2 instances

Full step-by-step walkthrough (console clicks, security groups,
exact commands per box): **[docs/v1-manual-ec2-deployment.md](../docs/v1-manual-ec2-deployment.md)**.

Short version: this needs **5** instances, not 4 — nginx gets its own
box too. Docker's bridge network doesn't span hosts, so service-name
DNS is replaced by each instance's **private IP**, and the same
tiering that's enforced by config here is additionally enforced by
**security groups** there: the backend's security group only accepts
inbound traffic from the frontend instances' security group — nginx's
security group has no rule allowing it to reach backend at all, so the
constraint holds even if a config file is ever wrong.
