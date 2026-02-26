#!/usr/bin/env bash
# stop.sh — tear down all matrix-easy-deploy services (data is preserved)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/scripts/lib.sh"
DOCKER_COMPOSE="$(docker_compose_cmd)"

info "Stopping calls services (coturn + LiveKit)…"
(cd "${SCRIPT_DIR}/modules/calls" && $DOCKER_COMPOSE down)

info "Stopping core services…"
(cd "${SCRIPT_DIR}/modules/core" && $DOCKER_COMPOSE down)

info "Stopping Caddy…"
(cd "${SCRIPT_DIR}/caddy" && $DOCKER_COMPOSE down)

success "All services stopped. Your data is intact in Docker volumes."
