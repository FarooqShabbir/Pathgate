#!/usr/bin/env bash
# Builds both Vite apps and syncs the output into S3 under a key
# prefix that matches the URL path CloudFront routes to that bucket
# (app1/, app2/). VITE_API_BASE=/api is required here: like the ALB
# in a load-balanced setup, CloudFront does not strip /app1/ before
# forwarding, so the frontend has to call the site root's literal
# /api/* (which CloudFront's own /api/* behavior routes to API
# Gateway) instead of the relative path v1/Beanstalk use. See
# apps/frontend-insert/src/App.jsx.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/.env.foundation"
ROOT="$(cd "$HERE/../.." && pwd)"

: "${APP1_BUCKET:?run ./02-setup-cloudfront.sh first}"

# MSYS_NO_PATHCONV=1 only matters on Windows Git Bash: without it,
# MSYS silently rewrites the "/api" env value into a bogus filesystem
# path before node ever sees it. Harmless no-op on Linux/macOS.
(cd "$ROOT/apps/frontend-insert" && npm install && MSYS_NO_PATHCONV=1 VITE_API_BASE=/api npm run build)
(cd "$ROOT/apps/frontend-list" && npm install && MSYS_NO_PATHCONV=1 VITE_API_BASE=/api npm run build)

aws s3 sync "$ROOT/apps/frontend-insert/dist" "s3://$APP1_BUCKET/app1" --delete --region "$AWS_REGION"
aws s3 sync "$ROOT/apps/frontend-list/dist" "s3://$APP2_BUCKET/app2" --delete --region "$AWS_REGION"

aws cloudfront create-invalidation --distribution-id "$DIST_ID" --paths '/app1/*' '/app2/*' --region "$AWS_REGION" >/dev/null

echo "Open https://$DIST_DOMAIN/app1 and /app2"
