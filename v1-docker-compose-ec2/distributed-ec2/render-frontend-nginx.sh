#!/usr/bin/env bash
# Run ON each frontend instance, after the backend instance is up and
# you know its private IP. Run once per frontend instance, pointing
# TARGET at that instance's own copy of frontend-insert/ or
# frontend-list/.
#
# Usage:
#   BACKEND_IP=10.0.1.21 ./render-frontend-nginx.sh ~/pathgate/apps/frontend-insert
set -euo pipefail

: "${BACKEND_IP:?export BACKEND_IP=<backend private IP> first}"
TARGET="${1:?Usage: BACKEND_IP=<ip> $0 <path to apps/frontend-insert or apps/frontend-list>}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
envsubst '${BACKEND_IP}' < "$HERE/nginx-frontend.conf.template" > "$TARGET/nginx.conf"
echo "Wrote $TARGET/nginx.conf -- now: cd $TARGET && docker build -t pathgate-frontend-<insert|list> ."
