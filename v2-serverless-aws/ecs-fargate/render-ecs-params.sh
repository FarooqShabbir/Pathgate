#!/usr/bin/env bash
# Renders <service>/ecs-params.yml.template -> <service>/ecs-params.yml
# using the values in .env.foundation. Called by deploy.sh for each
# service; run standalone as `./render-ecs-params.sh db` if you just
# want to inspect the rendered file.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/.env.foundation"

SERVICE="${1:?Usage: $0 <db|backend|frontend1|frontend2|nginx>}"
envsubst < "$HERE/$SERVICE/ecs-params.yml.template" > "$HERE/$SERVICE/ecs-params.yml"
echo "Wrote $HERE/$SERVICE/ecs-params.yml"
