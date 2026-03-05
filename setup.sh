#!/usr/bin/env bash
# =============================================================================
#  matrix-easy-deploy  —  setup.sh
#  Interactive setup wizard entrypoint for a self-hosted Matrix homeserver.
#
#  This file orchestrates the setup flow and delegates implementation details
#  to scripts under scripts/setup/.
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/scripts/lib.sh"
# shellcheck source=scripts/sso.sh
source "${SCRIPT_DIR}/scripts/sso.sh"

# shellcheck source=scripts/setup/banner.sh
source "${SCRIPT_DIR}/scripts/setup/banner.sh"
# shellcheck source=scripts/setup/dependencies.sh
source "${SCRIPT_DIR}/scripts/setup/dependencies.sh"
# shellcheck source=scripts/setup/config.sh
source "${SCRIPT_DIR}/scripts/setup/config.sh"
# shellcheck source=scripts/setup/generate.sh
source "${SCRIPT_DIR}/scripts/setup/generate.sh"
# shellcheck source=scripts/setup/runtime.sh
source "${SCRIPT_DIR}/scripts/setup/runtime.sh"
# shellcheck source=scripts/setup/summary.sh
source "${SCRIPT_DIR}/scripts/setup/summary.sh"
# shellcheck source=scripts/setup/modules.sh
source "${SCRIPT_DIR}/scripts/setup/modules.sh"

IFS=' ' read -ra DOCKER_COMPOSE <<< "$(docker_compose_cmd)"
DEPLOY_ENV="${SCRIPT_DIR}/.env"

main() {
    if [[ "${1:-}" == "--module" ]]; then
        shift
        local module="${1:?Usage: setup.sh --module <module-name>}"
        run_module_setup "$module"
        exit 0
    fi

    print_banner
    check_dependencies

    echo
    echo -e "${BOLD}  Step 1 of 5 — Configuration${RESET}"
    gather_config

    echo
    echo -e "${BOLD}  Step 2 of 5 — Generating configuration files${RESET}"
    generate_config

    echo
    echo -e "${BOLD}  Step 3 of 5 — Docker infrastructure${RESET}"
    setup_docker

    echo
    echo -e "${BOLD}  Step 4 of 5 — Starting services${RESET}"
    start_services

    echo
    echo -e "${BOLD}  Step 5 of 5 — Creating admin user${RESET}"
    setup_admin

    print_summary
}

main "$@"
