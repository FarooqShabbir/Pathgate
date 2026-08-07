#!/usr/bin/env bash
# Deploys all 5 services in dependency order with `ecs-cli compose
# service up`, waiting for each to stabilize before starting the next
# (db before backend, backend before the frontends, frontends before
# nginx) -- the same ordering v1's docker-compose `depends_on` chain
# expresses, just done as explicit steps since ecs-cli has no
# equivalent of depends_on across separate projects/services.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/.env.foundation"

: "${BACKEND_IMAGE:?run ./build_push.sh first}"

deploy_one() {
  local dir="$1" project="$2"
  "$HERE/render-ecs-params.sh" "$dir"
  (cd "$HERE/$dir" && ecs-cli compose --project-name "$project" \
    --file docker-compose.yml --ecs-params ecs-params.yml \
    service up --create-log-groups --launch-type FARGATE --cluster-config pathgate-ecscli)
  aws ecs wait services-stable --cluster "$CLUSTER_NAME" --services "$project" --region "$AWS_REGION"
  echo "== $project stable =="
}

deploy_one db pathgate-db
deploy_one backend pathgate-backend
deploy_one frontend1 pathgate-frontend1
deploy_one frontend2 pathgate-frontend2
deploy_one nginx pathgate-nginx

echo "== Finding nginx's public IP (no load balancer -- this IS the entry point) =="
TASK_ARN="$(aws ecs list-tasks --cluster "$CLUSTER_NAME" --service-name pathgate-nginx \
  --region "$AWS_REGION" --query 'taskArns[0]' --output text)"
ENI_ID="$(aws ecs describe-tasks --cluster "$CLUSTER_NAME" --tasks "$TASK_ARN" --region "$AWS_REGION" \
  --query 'tasks[0].attachments[0].details[?name==`networkInterfaceId`].value | [0]' --output text)"
PUBLIC_IP="$(aws ec2 describe-network-interfaces --network-interface-ids "$ENI_ID" --region "$AWS_REGION" \
  --query 'NetworkInterfaces[0].Association.PublicIp' --output text)"

echo "Open http://$PUBLIC_IP/app1 and http://$PUBLIC_IP/app2"
echo "NOTE: this IP changes if the nginx task is ever replaced (deploy,"
echo "crash, scale event) -- there's no load balancer providing a"
echo "stable DNS name in front of it. See README.md's hardening note."
