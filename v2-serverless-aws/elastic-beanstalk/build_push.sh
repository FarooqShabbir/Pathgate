#!/usr/bin/env bash
# Builds & pushes the 4 images -- v1's plain Dockerfiles, unchanged,
# since this variant keeps v1's nginx as the sole path router (same
# reasoning as the ECS Fargate compose variant: no ALB/CloudFront in
# front of it, so nothing needs to be prefix-aware on its own).
# Creates the 4 ECR repos if they don't exist yet (plain AWS CLI, no
# Terraform), then renders .ebextensions/01-environment.config with
# the resulting image URIs and POSTGRES_PASSWORD so `eb create` picks
# them up on the first deploy.
set -euo pipefail

: "${POSTGRES_PASSWORD:?export POSTGRES_PASSWORD=<a strong password> first}"

REGION="${AWS_REGION:-us-east-1}"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
REGISTRY="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"

for repo in pathgate-eb-compose-backend pathgate-eb-compose-frontend-insert pathgate-eb-compose-frontend-list pathgate-eb-compose-nginx; do
  aws ecr describe-repositories --repository-names "$repo" --region "$REGION" >/dev/null 2>&1 \
    || aws ecr create-repository --repository-name "$repo" --region "$REGION" >/dev/null
done

aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "$REGISTRY"

docker build -t "$REGISTRY/pathgate-eb-compose-backend:latest" "$ROOT/apps/backend"
docker push "$REGISTRY/pathgate-eb-compose-backend:latest"

docker build -t "$REGISTRY/pathgate-eb-compose-frontend-insert:latest" "$ROOT/apps/frontend-insert"
docker push "$REGISTRY/pathgate-eb-compose-frontend-insert:latest"

docker build -t "$REGISTRY/pathgate-eb-compose-frontend-list:latest" "$ROOT/apps/frontend-list"
docker push "$REGISTRY/pathgate-eb-compose-frontend-list:latest"

docker build -t "$REGISTRY/pathgate-eb-compose-nginx:latest" "$ROOT/v1-docker-compose-ec2/nginx"
docker push "$REGISTRY/pathgate-eb-compose-nginx:latest"

mkdir -p "$HERE/.ebextensions"
BACKEND_IMAGE="$REGISTRY/pathgate-eb-compose-backend:latest" \
FRONTEND_INSERT_IMAGE="$REGISTRY/pathgate-eb-compose-frontend-insert:latest" \
FRONTEND_LIST_IMAGE="$REGISTRY/pathgate-eb-compose-frontend-list:latest" \
NGINX_IMAGE="$REGISTRY/pathgate-eb-compose-nginx:latest" \
POSTGRES_PASSWORD="$POSTGRES_PASSWORD" \
  envsubst < "$HERE/01-environment.config.template" > "$HERE/.ebextensions/01-environment.config"

echo "Wrote $HERE/.ebextensions/01-environment.config"
echo "Now: eb init  &&  eb create   (or 'eb deploy' if the environment already exists)"
