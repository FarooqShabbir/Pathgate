#!/usr/bin/env bash
# One-time setup: security groups (no ALB/target-group security group
# anywhere -- sg-nginx is the only one open to 0.0.0.0/0), 4 ECR
# repos, the Fargate task execution role, an ECS cluster, and the
# `ecs-cli` config profile/cluster pointer. Run once; safe to re-run
# (skips anything that already exists). Writes resource IDs to
# .env.foundation (gitignored) for the other scripts to source.
set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

: "${VPC_ID:?export VPC_ID=<your VPC id> first}"
: "${SUBNET_ID:?export SUBNET_ID=<a public subnet id in that VPC, with a route to an internet gateway and auto-assign-public-IP enabled> first}"

echo "== Security groups (tiered, same pattern as the v1 manual EC2 guide) =="

get_or_create_sg() {
  local name="$1" desc="$2"
  local id
  id="$(aws ec2 describe-security-groups --filters "Name=group-name,Values=$name" "Name=vpc-id,Values=$VPC_ID" \
    --query 'SecurityGroups[0].GroupId' --output text --region "$REGION" 2>/dev/null || true)"
  if [ -z "$id" ] || [ "$id" = "None" ]; then
    id="$(aws ec2 create-security-group --group-name "$name" --description "$desc" --vpc-id "$VPC_ID" \
      --region "$REGION" --query 'GroupId' --output text)"
  fi
  echo "$id"
}

SG_NGINX_ID="$(get_or_create_sg pathgate-ecscli-nginx "Pathgate ECS CLI: nginx, public")"
SG_FRONTEND_ID="$(get_or_create_sg pathgate-ecscli-frontend "Pathgate ECS CLI: frontend1/2")"
SG_BACKEND_ID="$(get_or_create_sg pathgate-ecscli-backend "Pathgate ECS CLI: backend")"
SG_DB_ID="$(get_or_create_sg pathgate-ecscli-db "Pathgate ECS CLI: db")"

authorize() {
  local group="$1" port="$2" source="$3"
  aws ec2 authorize-security-group-ingress --group-id "$group" --protocol tcp --port "$port" \
    --source-group "$source" --region "$REGION" 2>/dev/null || true   # 2>/dev/null: idempotent, ignore "already exists"
}

# nginx: the ONLY rule in this whole stack open to the internet.
aws ec2 authorize-security-group-ingress --group-id "$SG_NGINX_ID" --protocol tcp --port 80 \
  --cidr 0.0.0.0/0 --region "$REGION" 2>/dev/null || true
authorize "$SG_FRONTEND_ID" 3000 "$SG_NGINX_ID"
authorize "$SG_BACKEND_ID" 8000 "$SG_FRONTEND_ID"
authorize "$SG_DB_ID" 5432 "$SG_BACKEND_ID"

echo "== ECR repositories =="
for repo in pathgate-ecscli-backend pathgate-ecscli-frontend-insert pathgate-ecscli-frontend-list pathgate-ecscli-nginx; do
  aws ecr describe-repositories --repository-names "$repo" --region "$REGION" >/dev/null 2>&1 \
    || aws ecr create-repository --repository-name "$repo" --region "$REGION" >/dev/null
done

echo "== Task execution role =="
ROLE_NAME="pathgate-ecscli-execution-role"
if ! aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  aws iam create-role --role-name "$ROLE_NAME" --assume-role-policy-document '{
    "Version": "2012-10-17",
    "Statement": [{"Effect": "Allow", "Principal": {"Service": "ecs-tasks.amazonaws.com"}, "Action": "sts:AssumeRole"}]
  }' >/dev/null
  aws iam attach-role-policy --role-name "$ROLE_NAME" \
    --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy
fi
EXECUTION_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}"

echo "== ECS cluster =="
CLUSTER_NAME="pathgate-ecscli-cluster"
aws ecs describe-clusters --clusters "$CLUSTER_NAME" --region "$REGION" \
  --query 'clusters[0].status' --output text 2>/dev/null | grep -q ACTIVE \
  || aws ecs create-cluster --cluster-name "$CLUSTER_NAME" --region "$REGION" >/dev/null

echo "== ecs-cli config (used by every service's 'ecs-cli compose ... service up') =="
ecs-cli configure --cluster "$CLUSTER_NAME" --region "$REGION" --default-launch-type FARGATE \
  --config-name pathgate-ecscli

cat > "$HERE/.env.foundation" <<EOF
export AWS_REGION="$REGION"
export ACCOUNT_ID="$ACCOUNT_ID"
export VPC_ID="$VPC_ID"
export SUBNET_ID="$SUBNET_ID"
export SG_NGINX_ID="$SG_NGINX_ID"
export SG_FRONTEND_ID="$SG_FRONTEND_ID"
export SG_BACKEND_ID="$SG_BACKEND_ID"
export SG_DB_ID="$SG_DB_ID"
export EXECUTION_ROLE_ARN="$EXECUTION_ROLE_ARN"
export CLUSTER_NAME="$CLUSTER_NAME"
EOF
echo "Wrote $HERE/.env.foundation"
echo "Next: POSTGRES_PASSWORD=<pick one> ./build_push.sh"
