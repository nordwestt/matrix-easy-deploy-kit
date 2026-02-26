#!/usr/bin/env bash
# start.sh — bring up all matrix-easy-deploy services
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/scripts/lib.sh"
DOCKER_COMPOSE="$(docker_compose_cmd)"

info "Starting Caddy…"
(cd "${SCRIPT_DIR}/caddy" && $DOCKER_COMPOSE up -d)

info "Starting core services…"
# Load .env if it exists so POSTGRES_PASSWORD is available
if [[ -f "${SCRIPT_DIR}/.env" ]]; then
    set -o allexport
    # shellcheck disable=SC1090
    source "${SCRIPT_DIR}/.env"
    set +o allexport
fi
(cd "${SCRIPT_DIR}/modules/core" && $DOCKER_COMPOSE up -d)

success "All services started."
