#!/usr/bin/env bash
# Builds & pushes the 4 custom images (db uses the public postgres
# image directly, nothing to build). Frontends use Dockerfile.ecs-cli
# (Cloud Map upstream), nginx uses this folder's own Dockerfile
# (Cloud Map downstreams). `ecs-cli compose` does not build images
# itself the way Docker's ECS integration does -- it expects images
# already pushed, same as the Elastic Beanstalk variant.
set -euo pipefail

: "${POSTGRES_PASSWORD:?export POSTGRES_PASSWORD=<a strong password> first}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/.env.foundation"
ROOT="$(cd "$HERE/../.." && pwd)"
REGISTRY="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

aws ecr get-login-password --region "$AWS_REGION" | docker login --username AWS --password-stdin "$REGISTRY"

docker build -t "$REGISTRY/pathgate-ecscli-backend:latest" "$ROOT/apps/backend"
docker push "$REGISTRY/pathgate-ecscli-backend:latest"

docker build -f "$ROOT/apps/frontend-insert/Dockerfile.ecs-cli" \
  -t "$REGISTRY/pathgate-ecscli-frontend-insert:latest" "$ROOT/apps/frontend-insert"
docker push "$REGISTRY/pathgate-ecscli-frontend-insert:latest"

docker build -f "$ROOT/apps/frontend-list/Dockerfile.ecs-cli" \
  -t "$REGISTRY/pathgate-ecscli-frontend-list:latest" "$ROOT/apps/frontend-list"
docker push "$REGISTRY/pathgate-ecscli-frontend-list:latest"

docker build -t "$REGISTRY/pathgate-ecscli-nginx:latest" "$HERE/nginx"
docker push "$REGISTRY/pathgate-ecscli-nginx:latest"

cat >> "$HERE/.env.foundation" <<EOF
export BACKEND_IMAGE="$REGISTRY/pathgate-ecscli-backend:latest"
export FRONTEND_INSERT_IMAGE="$REGISTRY/pathgate-ecscli-frontend-insert:latest"
export FRONTEND_LIST_IMAGE="$REGISTRY/pathgate-ecscli-frontend-list:latest"
export NGINX_IMAGE="$REGISTRY/pathgate-ecscli-nginx:latest"
export POSTGRES_PASSWORD="$POSTGRES_PASSWORD"
EOF
echo "Images pushed; image URIs + POSTGRES_PASSWORD appended to $HERE/.env.foundation"
echo "Next: ./deploy.sh"
