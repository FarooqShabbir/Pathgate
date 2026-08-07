#!/usr/bin/env bash
# Reverse of deploy.sh, plus the one-time foundation resources.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/.env.foundation"

for dir_project in "nginx pathgate-nginx" "frontend2 pathgate-frontend2" "frontend1 pathgate-frontend1" "backend pathgate-backend" "db pathgate-db"; do
  set -- $dir_project
  dir="$1"; project="$2"
  echo "== Removing $project =="
  (cd "$HERE/$dir" && ecs-cli compose --project-name "$project" \
    --file docker-compose.yml --ecs-params ecs-params.yml \
    service down --cluster-config pathgate-ecscli) || true
done

echo "== Deleting ECS cluster =="
aws ecs delete-cluster --cluster "$CLUSTER_NAME" --region "$AWS_REGION" >/dev/null || true

echo "== Deleting ECR repositories (and their images) =="
for repo in pathgate-ecscli-backend pathgate-ecscli-frontend-insert pathgate-ecscli-frontend-list pathgate-ecscli-nginx; do
  aws ecr delete-repository --repository-name "$repo" --force --region "$AWS_REGION" >/dev/null 2>&1 || true
done

echo "== Deleting Cloud Map namespace 'pathgate.local' (services must be gone first) =="
NS_ID="$(aws servicediscovery list-namespaces --region "$AWS_REGION" \
  --query "Namespaces[?Name=='pathgate.local'].Id | [0]" --output text)"
if [ -n "$NS_ID" ] && [ "$NS_ID" != "None" ]; then
  aws servicediscovery delete-namespace --id "$NS_ID" --region "$AWS_REGION" >/dev/null 2>&1 || true
fi

echo "== Deleting security groups =="
for sg in "$SG_NGINX_ID" "$SG_FRONTEND_ID" "$SG_BACKEND_ID" "$SG_DB_ID"; do
  aws ec2 delete-security-group --group-id "$sg" --region "$AWS_REGION" 2>/dev/null || true
done

echo "== Detaching + deleting the execution role =="
aws iam detach-role-policy --role-name pathgate-ecscli-execution-role \
  --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy 2>/dev/null || true
aws iam delete-role --role-name pathgate-ecscli-execution-role 2>/dev/null || true

echo "Done. If any step above printed an error, it likely means that"
echo "resource had a dependent still attached -- re-run this script"
echo "once after a minute, most of these calls are safe to repeat."
