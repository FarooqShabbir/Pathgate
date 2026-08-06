#!/usr/bin/env bash
# Builds both Vite apps and syncs the output into S3 under a key
# prefix that matches the URL path CloudFront routes to that bucket
# (app1/, app2/) -- the base:'./' asset paths need no per-deployment
# change. VITE_API_BASE=/api DOES need setting here, though: like the
# ALB in the ECS Fargate variant, CloudFront does not strip /app1/
# before forwarding, so the frontend has to call the site root's
# literal /api/* (which CloudFront's own /api/* behavior routes to
# API Gateway) instead of the relative path v1/Beanstalk use. See
# apps/frontend-insert/src/App.jsx.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)/.."

APP1_BUCKET="$(terraform -chdir="$HERE/terraform" output -raw frontend_insert_bucket)"
APP2_BUCKET="$(terraform -chdir="$HERE/terraform" output -raw frontend_list_bucket)"
DIST_ID="$(terraform -chdir="$HERE/terraform" output -raw cloudfront_distribution_id)"

# MSYS_NO_PATHCONV=1 only matters on Windows Git Bash: without it,
# MSYS silently rewrites the "/api" env value into a bogus filesystem
# path (e.g. "C:/Program Files/Git/api") before node ever sees it.
# Harmless no-op on Linux/macOS.
(cd "$ROOT/apps/frontend-insert" && npm install && MSYS_NO_PATHCONV=1 VITE_API_BASE=/api npm run build)
(cd "$ROOT/apps/frontend-list" && npm install && MSYS_NO_PATHCONV=1 VITE_API_BASE=/api npm run build)

aws s3 sync "$ROOT/apps/frontend-insert/dist" "s3://$APP1_BUCKET/app1" --delete
aws s3 sync "$ROOT/apps/frontend-list/dist" "s3://$APP2_BUCKET/app2" --delete

aws cloudfront create-invalidation --distribution-id "$DIST_ID" --paths '/app1/*' '/app2/*'
