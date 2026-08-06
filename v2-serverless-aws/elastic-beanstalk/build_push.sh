#!/usr/bin/env bash
# Builds all 4 images with v1's original (unmodified) Dockerfiles --
# this variant's nginx does the same prefix-stripping v1's does, so
# the frontends don't need the ECS-specific images.
set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
REGISTRY="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "$REGISTRY"

docker build -t "$REGISTRY/pathgate-eb-backend:latest" "$ROOT/apps/backend"
docker push "$REGISTRY/pathgate-eb-backend:latest"

docker build -t "$REGISTRY/pathgate-eb-frontend-insert:latest" "$ROOT/apps/frontend-insert"
docker push "$REGISTRY/pathgate-eb-frontend-insert:latest"

docker build -t "$REGISTRY/pathgate-eb-frontend-list:latest" "$ROOT/apps/frontend-list"
docker push "$REGISTRY/pathgate-eb-frontend-list:latest"

docker build -t "$REGISTRY/pathgate-eb-nginx:latest" "$ROOT/v1-docker-compose-ec2/nginx"
docker push "$REGISTRY/pathgate-eb-nginx:latest"

echo "Pushed. Now: eb deploy (or terraform apply again + eb CLI, or update the environment's compose file version)."
