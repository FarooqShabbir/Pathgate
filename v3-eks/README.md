# v3 — v1 on EKS (Kubernetes-native, no shortcuts to other AWS services)

Same application, same rule, on a real Kubernetes cluster — this
variant exists specifically to learn Kubernetes' own object model, not
to minimize AWS surface the way the v2 track did. `db` stays *inside*
the cluster as a proper StatefulSet, not punted out to RDS; the
cluster runs on a real EC2-backed managed node group, not Fargate,
specifically because `db` needs EBS-backed storage and Fargate pods
cannot mount EBS volumes at all.

## The shape

```
Client
  │ :80/:443
  ▼
ALB (provisioned by the AWS Load Balancer Controller, from the Ingress below)
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

Ingress only ever routes `/app1` and `/app2` — there is no `/api` rule.
Each frontend's own nginx (`apps/frontend-insert/nginx.eks.conf`)
proxies its `/api` calls to `backend` itself, the same tiering as v1,
Elastic Beanstalk, and ECS Fargate (`ecs-cli`) — the ALB doesn't strip
a matched path any more than an ALB anywhere else in this project
does, so the frontends have to be prefix-aware themselves
(`Dockerfile.eks`), same reasoning as `Dockerfile.ecs-cli`.

## Why this differs from the v2 track's instincts

- **db is a StatefulSet + PVC, not RDS.** Moving it to a managed AWS
  service would "solve" the Fargate/EBS conflict by removing the
  actual Kubernetes learning material — the whole point here.
- **Compute is a managed node group, not Fargate.** Once `db` needs
  EBS, Fargate is off the table for the *entire* cluster (not worth
  splitting compute models to save EC2 exposure on 3 of 4 workloads —
  that was the v2-era instinct, not relevant to a cluster that's
  already running EC2-backed nodes for `db`).
- **HPA is paired with Cluster Autoscaler**, not left to scale Pods
  into a full node group where they'd sit `Pending` — pod-level and
  node-level scaling, both present, doing their actual jobs.

## Kubernetes features this actually exercises

| Feature | Where |
|---|---|
| Namespace | `manifests/00-namespace.yaml` |
| StorageClass (dynamic provisioning) | `manifests/01-storageclass.yaml` |
| Secret | created imperatively (`kubectl create secret generic`) |
| StatefulSet + `volumeClaimTemplates` | `manifests/03-db-statefulset.yaml` |
| Headless Service | `manifests/04-db-service.yaml` |
| ConfigMap (mounted via `subPath`) | created imperatively from `apps/frontend-*/nginx.eks.conf` |
| Deployment | `manifests/05-`, `07-`, `09-` |
| ClusterIP Service | `manifests/06-`, `08-`, `10-` |
| readiness/liveness probes | every workload |
| resource requests/limits | every workload |
| IngressClass + Ingress | `manifests/11-`, `12-` |
| HorizontalPodAutoscaler | `manifests/13-`, `14-`, `15-` |
| IRSA (IAM Roles for Service Accounts) | Cluster Autoscaler, AWS Load Balancer Controller, the EBS CSI driver addon |
| Cluster Autoscaler | installed from the upstream manifest |
| metrics-server | installed from the upstream manifest |

## Prerequisites

- `eksctl`, `kubectl`, `aws-cli` v2, Docker.
- `aws sts get-caller-identity` working with credentials that can
  create EKS clusters, EC2 instances, IAM roles, and an ALB.

## Deploy

There are no scripts here — every command (cluster creation, IRSA
setup, Cluster Autoscaler/metrics-server/ALB Controller install,
image build/push, manifest rendering, and `kubectl apply`, in order)
is typed out individually, with an explanation of what it does and
why, in **[docs/v3-eks-manual-deployment.md](../docs/v3-eks-manual-deployment.md)**.
Follow it top to bottom for a first deploy.

Once the cluster and app are both up:
```bash
kubectl get ingress pathgate-ingress -n pathgate
```
Open `http://<ADDRESS>/app1` and `/app2` once the ALB shows an
address (a few minutes after the Ingress is applied).

## Verify the Kubernetes-specific pieces, not just "does the app load"

```bash
kubectl get statefulset,pods -n pathgate -l app=db     # db-0, one Pod, one PVC
kubectl get pvc -n pathgate                             # Bound, gp3
kubectl get hpa -n pathgate                              # current vs target CPU %
kubectl top pods -n pathgate                              # needs metrics-server
kubectl -n kube-system logs deployment/cluster-autoscaler | tail -20
```

To actually see HPA and Cluster Autoscaler do something, generate
load against `backend` (e.g. a quick `hey`/`ab` loop against
`/app1/api/items`) and watch `kubectl get hpa -n pathgate -w` react,
then `kubectl get nodes -w` if replica growth ever needs more capacity
than the node group currently has.

## Troubleshooting

- **PVC stuck `Pending`**: `kubectl describe pvc db-data-db-0 -n pathgate` —
  almost always the EBS CSI driver's IRSA role missing (check the
  addon's ServiceAccount annotation) or `WaitForFirstConsumer` waiting
  on `db-0` to be scheduled first (expected, resolves once it is).
- **Ingress has no `ADDRESS`**: `kubectl -n kube-system logs deployment/aws-load-balancer-controller` —
  usually a missing IRSA annotation on `aws-load-balancer-controller`'s
  ServiceAccount (same class of bug that hit the Elastic Beanstalk
  variant's placeholder substitution — verify with `kubectl get sa
  aws-load-balancer-controller -n kube-system -o yaml`, don't assume).
- **HPA shows `<unknown>/70%`**: metrics-server isn't installed or
  hasn't reported yet — `kubectl top pods -n pathgate`, if that errors
  metrics-server is the problem, not HPA.
- **Pods `Pending`, node group at `maxSize`**: expected — Cluster
  Autoscaler stops there on purpose. Raise `maxSize` in `cluster.yaml`
  and re-run `eksctl update nodegroup` if genuinely needed.

## Teardown

Typed step-by-step, in the right order (Ingress → namespace → cluster)
so nothing gets orphaned: **[docs/v3-eks-manual-deployment.md §19](../docs/v3-eks-manual-deployment.md#19-cost-and-cleanup)**.
This is the most expensive-to-forget-about part of this whole project
if left running — the EKS control plane bills hourly on its own, on
top of the node group's EC2 instances and the ALB.
