#!/usr/bin/env bash
# install-synapse-http-antispam.sh
# Installs synapse-http-antispam inside the running matrix_synapse container.
#
# Usage:
#   bash scripts/install-synapse-http-antispam.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

CONTAINER_NAME="matrix_synapse"
PACKAGE_NAME="synapse-http-antispam"

if ! command -v docker &>/dev/null; then
    die "Docker is not installed."
fi

if ! docker info &>/dev/null 2>&1; then
    die "Docker daemon is not running (or you need sudo)."
fi

if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    die "Container '${CONTAINER_NAME}' is not running. Start core services first (bash start.sh)."
fi

info "Installing ${PACKAGE_NAME} in ${CONTAINER_NAME}…"

if ! docker exec -u 0 "${CONTAINER_NAME}" python3 -m pip --version &>/dev/null; then
    info "pip not found in container; attempting bootstrap with ensurepip…"
    docker exec -u 0 "${CONTAINER_NAME}" python3 -m ensurepip --upgrade >/dev/null
fi

docker exec -u 0 "${CONTAINER_NAME}" \
    python3 -m pip install --no-cache-dir --upgrade "${PACKAGE_NAME}" >/dev/null

info "Verifying Python module import…"
docker exec "${CONTAINER_NAME}" python3 - <<'PYEOF'
import synapse_http_antispam  # noqa: F401
print("synapse_http_antispam import OK")
PYEOF

success "${PACKAGE_NAME} installed successfully in ${CONTAINER_NAME}."
warn "This installs into the current container filesystem; re-run after recreating/updating Synapse images."

info "Restarting Synapse…"
docker restart "${CONTAINER_NAME}" >/dev/null
success "Synapse restarted."

echo
info "Next checks:"
echo "  1) docker logs matrix_synapse | grep -i 'Loaded module'"
echo "  2) docker logs matrix_synapse | grep -i 'synapse_http_antispam'"
