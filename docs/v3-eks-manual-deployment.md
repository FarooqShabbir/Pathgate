# Deploying Pathgate v1 on Amazon EKS (manual, command-by-command)

Every command below is meant to be typed (or copy-pasted one at a time)
into your own shell, not run from a script — the point of this variant
is to actually see what `eksctl`/`kubectl`/`aws`/`docker` are doing at
each step, not to hide it behind `bash deploy.sh`. Run these from
wherever you have `eksctl`, `kubectl`, `aws-cli` v2, and `docker`
installed — your own machine, or the v1 EC2 instance you already have
running (it's a perfectly good build box for this too).

## 0. What you're deploying

```
Client
  │ :80/:443
  ▼
ALB (provisioned by the AWS Load Balancer Controller, from the Ingress)
  │  path=/app1            path=/app2
  ▼                          ▼
frontend1 Service          frontend2 Service        (ClusterIP, 2+ Pods each,
  │  (own nginx,              │  (own nginx,          scaled by HPA)
  │   proxies /app1/api/)     │   proxies /app2/api/)
  └───────────┬────────────────┘
              ▼
       backend Service (ClusterIP, 2+ Pods, scaled by HPA)
              │
              ▼
       db Service (headless) → db-0 (StatefulSet, 1 replica)
              │
              ▼
       PersistentVolumeClaim → EBS volume (gp3, via EBS CSI driver)
```

Same strict tier chain as every other variant: router → frontend →
backend → db, nobody skips a tier. The Ingress only ever routes
`/app1` and `/app2` — there's deliberately no `/api` rule at the ALB,
so each frontend's own nginx (`apps/frontend-insert/nginx.eks.conf`)
is what proxies `/app1/api/*` to `backend:8000/api/*`. If the ALB
routed `/api` directly to `backend`, that would let the browser skip
the frontend tier entirely — the same mistake documented as a warning
in the ECS Fargate variant.

**Compute**: one managed node group, real EC2 instances (`t3.medium`),
**not Fargate** — `db` needs an EBS-backed volume, and Fargate pods
cannot mount EBS at all (only EFS). Once one workload in the cluster
needs EC2, there's no benefit to splitting the rest onto Fargate — see
[v3-eks/README.md](../v3-eks/README.md#why-this-differs-from-the-v2-tracks-instincts)
for why that hybrid was considered and rejected for this lab.

**Worker nodes**: `cluster/cluster.yaml` sets `desiredCapacity: 2`,
`minSize: 2`, `maxSize: 4`. You start with **2 worker nodes** (enough
to spread `db`, `backend`, and both frontends across at least 2
machines so a single node failure doesn't take the whole app down).
Cluster Autoscaler can grow that to 4 if HPA scales enough Pods that
the 2 nodes run out of allocatable CPU/memory to place them on, and
shrinks back down to 2 once the extra capacity is idle. You'll watch
this happen in §18.

**Why there's now a ConfigMap** (there wasn't one in earlier revisions
of this variant): every other Pathgate variant bakes its nginx config
into the frontend image with `COPY nginx.*.conf ...` at build time —
changing routing means rebuilding and repushing the image. Here,
`apps/frontend-insert/nginx.eks.conf` and
`apps/frontend-list/nginx.eks.conf` are instead loaded into a
**ConfigMap** and mounted into the running container at
`/etc/nginx/conf.d/default.conf` (see `07-`/`09-frontend*-deployment.yaml.template`).
That's the Kubernetes-native way to decouple config from image: edit
the ConfigMap, restart the Deployment, no image rebuild. §13 creates
these two ConfigMaps directly from the existing `nginx.eks.conf`
files — there's no separate YAML for them, so there's only one place
the actual nginx config lives.

## 1. Prerequisites

- `aws-cli` v2, already configured (`aws sts get-caller-identity` works).
- `eksctl` (v0.180+): https://eksctl.io/installation/
- `kubectl` (matching the cluster's minor version, 1.31):
  https://kubernetes.io/docs/tasks/tools/#kubectl
- `docker`, logged in enough to build and push images.
- An IAM identity with permission to create EKS clusters, EC2
  instances/ASGs, IAM roles/policies, and (later) an ALB. This is a
  much bigger permission set than `pathgate-ssm-role` from v1 — use
  your own admin-capable credentials for the commands in this guide,
  not the EC2 instance's SSM role.

Confirm the basics:
```bash
aws sts get-caller-identity
eksctl version
kubectl version --client
```

Set a couple of variables you'll reuse throughout this guide:
```bash
export AWS_REGION=us-east-1
export CLUSTER_NAME=pathgate-eks
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
```
(These are just shell variables in your current session — if you
reconnect later, e.g. over SSM, re-export them before continuing.)

## 2. Create the EKS cluster

The cluster shape (control plane version, node group, add-ons) is
already defined in [v3-eks/cluster/cluster.yaml](../v3-eks/cluster/cluster.yaml).
Read it before running this — `eksctl` will create real, billable AWS
resources from it:

```bash
cat v3-eks/cluster/cluster.yaml
```

```bash
eksctl create cluster -f v3-eks/cluster/cluster.yaml
```

This takes **15–20 minutes**. It creates, in order: a dedicated VPC
(unless you point it at an existing one), the EKS control plane, an
OIDC provider for the cluster (needed for IRSA in §3 and §7), the
`pathgate-ng` managed node group (2 × `t3.medium`), and the
`vpc-cni`, `coredns`, `kube-proxy`, and `aws-ebs-csi-driver` add-ons.
The EBS CSI driver add-on is what lets `db`'s PersistentVolumeClaim
actually provision a real EBS volume later — `eksctl` wires its IRSA
role automatically via `wellKnownPolicies.ebsCSIController: true` in
the cluster config, so there's no separate IAM step for it like there
is for Cluster Autoscaler and the ALB Controller below.

`eksctl` also updates your local kubeconfig (`~/.kube/config`) to
point at the new cluster. Confirm:

```bash
kubectl get nodes
```
You should see 2 nodes in `Ready` state.

```bash
kubectl get pods -n kube-system
```
Confirms `coredns`, `kube-proxy`, `aws-node` (vpc-cni), and the
`ebs-csi-controller`/`ebs-csi-node` Pods are `Running`.

## 3. Install Cluster Autoscaler

Cluster Autoscaler is the **node-level** half of scaling: when HPA
(§16) grows a Deployment's replica count past what the 2 current nodes
can schedule, Cluster Autoscaler is what actually adds a 3rd/4th node
to the ASG so those Pods stop sitting `Pending`.

Download the upstream autodiscovery manifest and point it at this
cluster's name:
```bash
curl -Lo cluster-autoscaler-autodiscover.yaml \
  https://raw.githubusercontent.com/kubernetes/autoscaler/master/cluster-autoscaler/cloudprovider/aws/examples/cluster-autoscaler-autodiscover.yaml

sed -i.bak "s/<YOUR CLUSTER NAME>/${CLUSTER_NAME}/" cluster-autoscaler-autodiscover.yaml
```
Confirm the substitution actually landed before applying anything —
this is the exact class of bug (a literal placeholder left in a file)
that caused the Elastic Beanstalk incident in v2:
```bash
grep -n "cluster-autoscaler/${CLUSTER_NAME}" cluster-autoscaler-autodiscover.yaml
```
You should see the tag reference with `pathgate-eks` in it, not `<YOUR CLUSTER NAME>`.

Apply it:
```bash
kubectl apply -f cluster-autoscaler-autodiscover.yaml
```
This creates the `cluster-autoscaler` Deployment, a bare
`ServiceAccount` (no AWS permissions yet), and its ClusterRole/bindings
in `kube-system`.

Pin the image to a version matching the cluster's Kubernetes minor
version (1.31) — the autodiscovery manifest ships with a placeholder
tag that doesn't track your cluster automatically:
```bash
kubectl -n kube-system set image deployment/cluster-autoscaler \
  cluster-autoscaler=registry.k8s.io/autoscaling/cluster-autoscaler:v1.31.0
```

Stop Cluster Autoscaler from ever evicting *itself* while rebalancing
nodes:
```bash
kubectl -n kube-system patch deployment cluster-autoscaler -p \
  '{"spec":{"template":{"metadata":{"annotations":{"cluster-autoscaler.kubernetes.io/safe-to-evict":"false"}}}}}'
```

Now give it real AWS permissions via IRSA. This project uses the
AWS-managed `AutoScalingFullAccess` policy for simplicity — worth
naming plainly: that's broader than a hand-scoped policy limited to
this one ASG would be, a real production setup would tighten it, but
for a learning lab this keeps the IAM step to one command:
```bash
eksctl create iamserviceaccount \
  --cluster $CLUSTER_NAME \
  --namespace kube-system \
  --name cluster-autoscaler \
  --attach-policy-arn arn:aws:iam::aws:policy/AutoScalingFullAccess \
  --override-existing-serviceaccounts \
  --approve
```
`--override-existing-serviceaccounts` is what lets this annotate the
`ServiceAccount` the manifest already created in `kube-system`,
instead of erroring that it exists.

The running Pod was already scheduled *before* it had that annotation,
so it's still using the old, permission-less identity — restart it to
pick up the new one:
```bash
kubectl -n kube-system rollout restart deployment cluster-autoscaler
kubectl -n kube-system rollout status deployment cluster-autoscaler
```

Verify the annotation actually landed, then check the logs for
`AccessDenied` (don't just assume it worked):
```bash
kubectl get sa cluster-autoscaler -n kube-system -o yaml | grep role-arn
kubectl -n kube-system logs deployment/cluster-autoscaler --tail=20
```

## 4. Install metrics-server

HPA (§16) needs a CPU/memory data source to scale against — without
this, `kubectl get hpa` shows `<unknown>/70%` forever and never scales
anything.

```bash
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
kubectl -n kube-system rollout status deployment/metrics-server
```

Give it a minute to collect its first sample, then confirm:
```bash
kubectl top nodes
```

## 5. Set up IAM for the AWS Load Balancer Controller

This is the same IRSA pattern as Cluster Autoscaler, but with a
dedicated IAM policy (not an AWS-managed one) since AWS publishes an
exact policy JSON for this controller.

```bash
curl -Lo iam-policy-alb.json \
  https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.9.0/docs/install/iam_policy.json

aws iam create-policy \
  --policy-name AWSLoadBalancerControllerIAMPolicy \
  --policy-document file://iam-policy-alb.json
```
(If you've run this before and the policy already exists, `create-policy`
will error with `EntityAlreadyExists` — that's fine, just reuse the
existing ARN below.)

```bash
eksctl create iamserviceaccount \
  --cluster $CLUSTER_NAME \
  --namespace kube-system \
  --name aws-load-balancer-controller \
  --attach-policy-arn arn:aws:iam::${ACCOUNT_ID}:policy/AWSLoadBalancerControllerIAMPolicy \
  --override-existing-serviceaccounts \
  --approve
```

## 6. Install cert-manager

The ALB Controller's install manifest (`v2_9_0_full.yaml`, next
section) includes a `Certificate`/`Issuer` pair that **cert-manager**
is responsible for fulfilling — that's how the manifest gets the
webhook server's TLS cert without needing Helm's cert-generation job.
Install cert-manager **before** the ALB Controller, not after:

```bash
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml
```
```bash
kubectl -n cert-manager rollout status deployment/cert-manager
kubectl -n cert-manager rollout status deployment/cert-manager-webhook
kubectl -n cert-manager rollout status deployment/cert-manager-cainjector
```

**Why this order matters — a real deadlock if you get it backwards**:
the ALB Controller's `MutatingWebhookConfiguration` intercepts *every*
new `Service` object cluster-wide. If the ALB Controller is installed
first and its Pods are stuck waiting on a TLS secret that doesn't
exist yet, that webhook has zero ready endpoints — so when
cert-manager's own install tries to create *its* Services, the API
server calls out to a webhook that can't answer, and cert-manager's
install fails with `no endpoints available for service
"aws-load-balancer-webhook-service"`. Both sides end up blocking each
other. Installing cert-manager first avoids the deadlock entirely; if
you ever hit it anyway (e.g. reapplying out of order on an existing
cluster), the fix is to temporarily delete both of the ALB
Controller's webhook configs, let cert-manager finish, then reapply
`v2_9_0_full.yaml` (next section) to recreate them:
```bash
kubectl delete mutatingwebhookconfiguration aws-load-balancer-webhook --ignore-not-found
kubectl delete validatingwebhookconfiguration aws-load-balancer-webhook --ignore-not-found
```

## 7. Install the AWS Load Balancer Controller

This controller watches for `Ingress` objects and provisions/manages
the actual ALB — it's what turns `12-ingress.yaml` (§15) into a real,
internet-facing load balancer.

Install its CRDs first:
```bash
kubectl apply -k "github.com/aws/eks-charts/stable/aws-load-balancer-controller/crds?ref=master"
```

Download the controller's own install manifest and point it at this
cluster:
```bash
curl -Lo v2_9_0_full.yaml \
  https://github.com/kubernetes-sigs/aws-load-balancer-controller/releases/download/v2.9.0/v2_9_0_full.yaml

sed -i.bak "s/your-cluster-name/${CLUSTER_NAME}/" v2_9_0_full.yaml
```
Verify the substitution before applying, same habit as §3:
```bash
grep -n "cluster-name=${CLUSTER_NAME}" v2_9_0_full.yaml
```

```bash
kubectl apply -f v2_9_0_full.yaml
```
This creates the `aws-load-balancer-controller` Deployment in
`kube-system` plus a bare `ServiceAccount` — same situation as
Cluster Autoscaler: it exists, but has no AWS permissions yet.

Re-run the IRSA command from §5 with `--override-existing-serviceaccounts`
to attach the IAM role annotation to the `ServiceAccount` the manifest
just created:
```bash
eksctl create iamserviceaccount \
  --cluster $CLUSTER_NAME \
  --namespace kube-system \
  --name aws-load-balancer-controller \
  --attach-policy-arn arn:aws:iam::${ACCOUNT_ID}:policy/AWSLoadBalancerControllerIAMPolicy \
  --override-existing-serviceaccounts \
  --approve
```

Restart so the running Pod picks up the newly-annotated identity:
```bash
kubectl -n kube-system rollout restart deployment aws-load-balancer-controller
kubectl -n kube-system rollout status deployment aws-load-balancer-controller
```

Verify:
```bash
kubectl get sa aws-load-balancer-controller -n kube-system -o yaml | grep role-arn
kubectl -n kube-system logs deployment/aws-load-balancer-controller --tail=20
```
No `AccessDenied` in the logs means it's ready to provision an ALB
once an `Ingress` shows up (§15).

## 8. Build and push the 3 application images to ECR

The database uses the stock `postgres` image — nothing to build there.
The other 3 workloads (`backend`, `frontend1`, `frontend2`) need
building and pushing to ECR.

Create the 3 repositories (safe to re-run — `|| true` just swallows
the "already exists" error on repeat runs):
```bash
aws ecr create-repository --repository-name pathgate-eks-backend --region $AWS_REGION || true
aws ecr create-repository --repository-name pathgate-eks-frontend-insert --region $AWS_REGION || true
aws ecr create-repository --repository-name pathgate-eks-frontend-list --region $AWS_REGION || true
```

```bash
export ECR_REGISTRY=${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com
aws ecr get-login-password --region $AWS_REGION | docker login --username AWS --password-stdin $ECR_REGISTRY
```

Build and push the backend (same image as every other variant —
storage backend is chosen at runtime by `STORAGE_BACKEND`, not baked
in):
```bash
docker build -t $ECR_REGISTRY/pathgate-eks-backend:latest apps/backend
docker push $ECR_REGISTRY/pathgate-eks-backend:latest
```

Build and push both frontends using their EKS-specific Dockerfile —
note these do **not** bake in an nginx config (see §0's explanation);
that comes from the ConfigMap in §13:
```bash
docker build -f apps/frontend-insert/Dockerfile.eks -t $ECR_REGISTRY/pathgate-eks-frontend-insert:latest apps/frontend-insert
docker push $ECR_REGISTRY/pathgate-eks-frontend-insert:latest

docker build -f apps/frontend-list/Dockerfile.eks -t $ECR_REGISTRY/pathgate-eks-frontend-list:latest apps/frontend-list
docker push $ECR_REGISTRY/pathgate-eks-frontend-list:latest
```

Keep this shell session (or re-export `ECR_REGISTRY`) around — the
Deployment templates in §12 and §14 need it.

## 9. Namespace and StorageClass

```bash
kubectl apply -f v3-eks/manifests/00-namespace.yaml
kubectl apply -f v3-eks/manifests/01-storageclass.yaml
```

Confirm the `gp3` StorageClass is marked default (`db`'s PVC doesn't
specify `storageClassName` explicitly by accident — it relies on this):
```bash
kubectl get storageclass
```
You should see `gp3` with `(default)` next to its name.

## 10. Create the database credentials Secret

Unlike the other manifests, this one is created **imperatively**
rather than from a YAML file — for a Secret this small, typing the
values directly on the command line at creation time removes the
"forgot to render a template" bug class entirely (no intermediate file
to leave a placeholder in):

```bash
kubectl create secret generic pathgate-db-credentials \
  --namespace pathgate \
  --from-literal=POSTGRES_USER=pathgate \
  --from-literal=POSTGRES_PASSWORD='choose-a-strong-password' \
  --from-literal=POSTGRES_DB=pathgate
```
Pick your own password for `POSTGRES_PASSWORD` — this is what both
`db` (§11) and `backend` (§12) read via `envFrom: secretRef` to
authenticate to Postgres.

Confirm the keys (not the values) landed:
```bash
kubectl get secret pathgate-db-credentials -n pathgate -o jsonpath='{.data}' | tr ',' '\n'
```

## 11. Deploy the database

```bash
kubectl apply -f v3-eks/manifests/03-db-statefulset.yaml
kubectl apply -f v3-eks/manifests/04-db-service.yaml
```

This is a `StatefulSet`, not a `Deployment` — the right primitive for
`db` because it gives the Pod a stable identity (`db-0`) and, via
`volumeClaimTemplates`, its own dedicated `PersistentVolumeClaim` that
survives Pod restarts/rescheduling. `04-db-service.yaml` is a
**headless** Service (`clusterIP: None`) — it exists so `backend` can
resolve `db` to `db-0`'s actual Pod IP via DNS, rather than load
balancing across replicas that don't exist here (this StatefulSet
only ever runs 1 replica).

Watch it come up:
```bash
kubectl get statefulset,pods,pvc -n pathgate -w
```
Ctrl-C once `db-0` shows `1/1 Running` and the PVC shows `Bound`. This
can take a minute or two the first time — the EBS CSI driver has to
actually provision and attach a real EBS volume.

If the PVC sits `Pending`, see §19's troubleshooting entry before
assuming something's broken — `WaitForFirstConsumer` binding mode
means it's normal for it to stay `Pending` briefly until `db-0` is
scheduled.

## 12. Deploy the backend

Render the template with the registry value from §8:
```bash
envsubst < v3-eks/manifests/05-backend-deployment.yaml.template > v3-eks/manifests/05-backend-deployment.yaml
```
Check for a leftover, un-substituted placeholder before applying —
this is the exact check that would have caught the Elastic Beanstalk
`<REGISTRY>` incident immediately instead of 30 minutes into a stuck
deploy:
```bash
grep -n '\${' v3-eks/manifests/05-backend-deployment.yaml && echo "STOP: placeholder left unrendered" || echo "clean"
```
It should print `clean`. If it doesn't, `ECR_REGISTRY` wasn't exported
in this shell — re-export it from §8 and re-run `envsubst`.

```bash
kubectl apply -f v3-eks/manifests/05-backend-deployment.yaml
kubectl apply -f v3-eks/manifests/06-backend-service.yaml
```

```bash
kubectl get pods -n pathgate -l app=backend -w
```
Ctrl-C once both replicas show `Running` and `READY 1/1`. If they
don't, check `kubectl logs -n pathgate -l app=backend` — a common
first-run cause is the Secret from §10 not existing yet or a typo in
one of its keys.

## 13. Create the nginx ConfigMaps

These are created directly from the same `nginx.eks.conf` files the
frontend images reference at runtime — no separate ConfigMap YAML, so
there's exactly one place this config exists:

```bash
kubectl create configmap frontend1-nginx-config \
  --namespace pathgate \
  --from-file=default.conf=apps/frontend-insert/nginx.eks.conf

kubectl create configmap frontend2-nginx-config \
  --namespace pathgate \
  --from-file=default.conf=apps/frontend-list/nginx.eks.conf
```
The `default.conf=` prefix is what controls the *key* the file is
stored under inside the ConfigMap — it has to be `default.conf`
because `07-`/`09-frontend*-deployment.yaml.template` mount this
ConfigMap with `subPath: default.conf`, landing it at
`/etc/nginx/conf.d/default.conf` inside the container (nginx's default
include path), regardless of what the source file on disk is named.

Confirm:
```bash
kubectl get configmap -n pathgate
kubectl describe configmap frontend1-nginx-config -n pathgate
```

## 14. Deploy the frontends

Render both templates with the same `ECR_REGISTRY`:
```bash
envsubst < v3-eks/manifests/07-frontend1-deployment.yaml.template > v3-eks/manifests/07-frontend1-deployment.yaml
envsubst < v3-eks/manifests/09-frontend2-deployment.yaml.template > v3-eks/manifests/09-frontend2-deployment.yaml
```
Same placeholder check as §12, for both files this time:
```bash
grep -n '\${' v3-eks/manifests/07-frontend1-deployment.yaml v3-eks/manifests/09-frontend2-deployment.yaml && echo "STOP: placeholder left unrendered" || echo "clean"
```

```bash
kubectl apply -f v3-eks/manifests/07-frontend1-deployment.yaml
kubectl apply -f v3-eks/manifests/08-frontend1-service.yaml
kubectl apply -f v3-eks/manifests/09-frontend2-deployment.yaml
kubectl apply -f v3-eks/manifests/10-frontend2-service.yaml
```

```bash
kubectl get pods -n pathgate -l 'app in (frontend1,frontend2)' -w
```
Ctrl-C once all 4 Pods (2 per frontend) show `Running`, `1/1`. If a
Pod is `Running` but the readiness probe never passes, `kubectl
describe pod <name> -n pathgate` will usually show nginx failing to
start — check that the ConfigMap from §13 actually contains valid
nginx config (`kubectl exec` into the Pod and `cat
/etc/nginx/conf.d/default.conf` if unsure).

## 15. Deploy the Ingress

```bash
kubectl apply -f v3-eks/manifests/11-ingressclass.yaml
kubectl apply -f v3-eks/manifests/12-ingress.yaml
```

The AWS Load Balancer Controller from §7 is what's actually watching
for this — applying it triggers ALB creation in your AWS account.

```bash
kubectl get ingress pathgate-ingress -n pathgate -w
```
Ctrl-C once the `ADDRESS` column populates (a real ALB DNS name) —
this typically takes 2-3 minutes, the ALB itself has to be provisioned
in EC2, not just the Kubernetes object.

## 16. Deploy the HPAs

```bash
kubectl apply -f v3-eks/manifests/13-hpa-backend.yaml
kubectl apply -f v3-eks/manifests/14-hpa-frontend1.yaml
kubectl apply -f v3-eks/manifests/15-hpa-frontend2.yaml
```

```bash
kubectl get hpa -n pathgate
```
Each should show a real percentage under `TARGETS` (e.g. `3%/70%`),
not `<unknown>/70%` — if you see `<unknown>`, metrics-server (§4) isn't
reporting yet; give it another minute.

## 17. Verify the app end-to-end

```bash
INGRESS_ADDR=$(kubectl get ingress pathgate-ingress -n pathgate -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo $INGRESS_ADDR
```

Open `http://$INGRESS_ADDR/app1` (insert-only) and
`http://$INGRESS_ADDR/app2` (list-only) in a browser, or:
```bash
curl -s http://$INGRESS_ADDR/app1/api/items
curl -X POST http://$INGRESS_ADDR/app1/api/items -H 'Content-Type: application/json' -d '{"text":"hello from eks"}'
curl -s http://$INGRESS_ADDR/app2/api/items
```

## 18. Watch HPA and Cluster Autoscaler actually do something

This is the part that's easy to skip and easy to miss the point of —
both pieces of scaling only prove themselves under load:

```bash
kubectl get hpa -n pathgate -w
```
In another terminal, generate load against the backend (adjust the
tool to whatever you have — `hey`, `ab`, or even a tight curl loop):
```bash
for i in $(seq 1 5000); do curl -s http://$INGRESS_ADDR/app2/api/items > /dev/null; done
```
Watch the `TARGETS` percentage climb past 70% in the first terminal,
and `REPLICAS` grow. If replica growth needs more CPU than the 2
current nodes have allocatable, watch a 3rd/4th node appear:
```bash
kubectl get nodes -w
```
```bash
kubectl -n kube-system logs deployment/cluster-autoscaler --tail=30 -f
```
Look for lines like `Scale-up: setting group ... size to N`. Both
scale back down a few minutes after the load stops — HPA has a
default 5-minute-ish stabilization window before scaling in, Cluster
Autoscaler waits ~10 minutes of a node being underutilized before
removing it.

## 19. Troubleshooting

- **PVC stuck `Pending`**: `kubectl describe pvc db-data-db-0 -n pathgate`.
  Two normal-vs-broken cases look identical at a glance — check the
  `Events` at the bottom: `waiting for first consumer to be created
  before binding` is expected and resolves once `db-0` is scheduled;
  anything mentioning the EBS CSI driver or IAM is the addon's IRSA
  role missing (re-check `wellKnownPolicies.ebsCSIController: true` in
  `cluster.yaml` was actually applied — `eksctl get addon --cluster
  $CLUSTER_NAME`).
- **Ingress never gets an `ADDRESS`**:
  `kubectl -n kube-system logs deployment/aws-load-balancer-controller`.
  Almost always a missing or stale IRSA annotation — re-verify with
  `kubectl get sa aws-load-balancer-controller -n kube-system -o yaml`
  and re-run §7's `eksctl create iamserviceaccount` +
  `rollout restart` if the `eks.amazonaws.com/role-arn` annotation is
  missing.
- **HPA shows `<unknown>/70%` and never changes**: metrics-server
  isn't installed or hasn't reported yet —
  `kubectl top pods -n pathgate`; if that errors, fix metrics-server
  (§4) first, HPA can't do anything until that works.
- **Pods stuck `Pending`, node group already at `maxSize` (4)**:
  expected — Cluster Autoscaler stops there on purpose, it won't
  exceed the ASG's configured max. Either wait for load to drop or
  raise `maxSize` in `cluster.yaml` and run
  `eksctl scale nodegroup --cluster $CLUSTER_NAME --name pathgate-ng --nodes-max <N>`.
- **`envsubst: command not found`**: install it — it ships with
  `gettext` (`apt-get install gettext-base` on Debian/Ubuntu,
  `brew install gettext` on macOS).
- **A rendered `*.yaml` still contains `${...}`**: the export from an
  earlier section didn't survive into this shell (fresh terminal, SSM
  reconnect, etc.) — re-export the variable and re-run the `envsubst`
  command for that specific file before applying it.

## 20. Cost and cleanup

This is the most expensive variant in the whole project to leave
running — the EKS control plane alone is billed hourly regardless of
load, on top of 2-4 EC2 instances and an ALB. Tear it down when you're
done experimenting:

```bash
kubectl delete -f v3-eks/manifests/12-ingress.yaml
kubectl delete -f v3-eks/manifests/11-ingressclass.yaml
```
Deleting the `Ingress` first lets the AWS Load Balancer Controller
clean up the real ALB before the cluster itself goes away — deleting
the cluster first can orphan it as a dangling, still-billed resource.

```bash
kubectl delete namespace pathgate
```
This removes every app object at once (Deployments, Services, the
StatefulSet, the PVC — which also triggers deletion of the underlying
EBS volume — Secret, ConfigMaps, HPAs) since they're all in the
`pathgate` namespace.

Confirm the ALB is actually gone before proceeding (can take a couple
of minutes after the `Ingress` delete):
```bash
aws elbv2 describe-load-balancers --region $AWS_REGION --query "LoadBalancers[?contains(LoadBalancerName, 'k8s-pathgate')].LoadBalancerName"
```
Should return an empty list.

Finally, delete the cluster itself — this removes the control plane,
the node group's EC2 instances/ASG, and (unless you supplied an
existing VPC) the VPC `eksctl` created for it:
```bash
eksctl delete cluster --name $CLUSTER_NAME --region $AWS_REGION
```
This takes **10-15 minutes**. Confirm nothing billable is left over:
```bash
aws eks list-clusters --region $AWS_REGION
aws ec2 describe-instances --region $AWS_REGION --filters "Name=tag:alpha.eksctl.io/cluster-name,Values=$CLUSTER_NAME" --query "Reservations[].Instances[].State.Name"
```
Both should come back empty.

Optionally, remove the IAM policy created in §5 if you don't plan to
recreate this cluster:
```bash
aws iam delete-policy --policy-arn arn:aws:iam::${ACCOUNT_ID}:policy/AWSLoadBalancerControllerIAMPolicy
```
