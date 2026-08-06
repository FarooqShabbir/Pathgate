#!/usr/bin/env bash
# Run ON the nginx instance, after frontend1 and frontend2 are up and
# you know their private IPs.
#
# Usage:
#   FRONTEND1_IP=10.0.1.11 FRONTEND2_IP=10.0.1.12 \
#     ./render-gateway-nginx.sh ~/pathgate/v1-docker-compose-ec2/nginx
set -euo pipefail

: "${FRONTEND1_IP:?export FRONTEND1_IP=<frontend1 private IP> first}"
: "${FRONTEND2_IP:?export FRONTEND2_IP=<frontend2 private IP> first}"
TARGET="${1:?Usage: FRONTEND1_IP=<ip> FRONTEND2_IP=<ip> $0 <path to v1-docker-compose-ec2/nginx>}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
envsubst '${FRONTEND1_IP} ${FRONTEND2_IP}' < "$HERE/nginx-gateway.conf.template" > "$TARGET/nginx.conf"
echo "Wrote $TARGET/nginx.conf -- now: cd $TARGET && docker build -t pathgate-nginx ."
