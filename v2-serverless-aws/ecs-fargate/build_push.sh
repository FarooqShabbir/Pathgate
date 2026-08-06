#!/usr/bin/env bash
# Build the three images with their ECS-specific Dockerfiles and push
# them to the ECR repos Terraform created. Run `terraform apply` once
# first so the repos exist, then run this, then `terraform apply`
# again (or `aws ecs update-service --force-new-deployment`) to roll
# the new images out.
set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
REGISTRY="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "$REGISTRY"

docker build -t "$REGISTRY/pathgate-backend:latest" "$ROOT/apps/backend"
docker push "$REGISTRY/pathgate-backend:latest"

docker build -f "$ROOT/apps/frontend-insert/Dockerfile.ecs" -t "$REGISTRY/pathgate-frontend-insert:latest" "$ROOT/apps/frontend-insert"
docker push "$REGISTRY/pathgate-frontend-insert:latest"

docker build -f "$ROOT/apps/frontend-list/Dockerfile.ecs" -t "$REGISTRY/pathgate-frontend-list:latest" "$ROOT/apps/frontend-list"
docker push "$REGISTRY/pathgate-frontend-list:latest"

echo "Pushed. Now: terraform apply (or force a new ECS deployment per service)."
