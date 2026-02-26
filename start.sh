#!/usr/bin/env bash
# start.sh — bring up all matrix-easy-deploy services
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/scripts/lib.sh"
DOCKER_COMPOSE="$(docker_compose_cmd)"

info "Starting Caddy…"
(cd "${SCRIPT_DIR}/caddy" && $DOCKER_COMPOSE up -d)

info "Starting core services…"
# Load .env if it exists so POSTGRES_PASSWORD and INSTALL_ELEMENT are available
INSTALL_ELEMENT="true"  # default: assume Element is present if .env is missing
if [[ -f "${SCRIPT_DIR}/.env" ]]; then
    set -o allexport
    # shellcheck disable=SC1090
    source "${SCRIPT_DIR}/.env"
    set +o allexport
fi

_element_profile=""
if [[ "${INSTALL_ELEMENT:-true}" == "true" ]]; then
    _element_profile="--profile element"
fi

(cd "${SCRIPT_DIR}/modules/core" && $DOCKER_COMPOSE $_element_profile up -d)

success "All services started."
