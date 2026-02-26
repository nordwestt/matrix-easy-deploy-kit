#!/usr/bin/env bash
# =============================================================================
#  matrix-easy-deploy  —  setup.sh
#  Interactive setup wizard for a self-hosted Matrix homeserver.
#
#  Installs: Caddy (reverse proxy) + Synapse (homeserver) + Element (web client)
#  All services run via Docker Compose.
#
#  Usage:  bash setup.sh
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/scripts/lib.sh"

DOCKER_COMPOSE="$(docker_compose_cmd)"
DEPLOY_ENV="${SCRIPT_DIR}/.env"

# =============================================================================
# Banner
# =============================================================================
print_banner() {
    echo
    echo -e "${BOLD}${CYAN}"
    cat << 'EOF'
  ┌───────────────────────────────────────────────────┐
  │                                                   │
  │         m a t r i x - e a s y - d e p l o y      │
  │                                                   │
  │   Your Matrix homeserver, standing up straight.   │
  │                                                   │
  └───────────────────────────────────────────────────┘
EOF
    echo -e "${RESET}"
    echo -e "  This wizard will set up ${BOLD}Synapse${RESET} + ${BOLD}Element${RESET} + ${BOLD}Caddy${RESET} on this machine."
    echo -e "  It should take about ${CYAN}5 minutes${RESET}.\n"
}

# =============================================================================
# Step 1 — Dependency checks
# =============================================================================
check_dependencies() {
    info "Checking dependencies…"

    local missing=()

    # Docker daemon
    if ! command -v docker &>/dev/null; then
        missing+=("docker")
    elif ! docker info &>/dev/null 2>&1; then
        die "Docker is installed but the daemon isn't running (or you need sudo). Please start Docker and re-run."
    fi

    # Docker Compose
    if ! docker compose version &>/dev/null 2>&1 && ! command -v docker-compose &>/dev/null; then
        missing+=("docker-compose")
    fi

    # openssl (secret generation)
    if ! command -v openssl &>/dev/null; then
        missing+=("openssl")
    fi

    # curl (health checks, admin API)
    if ! command -v curl &>/dev/null; then
        missing+=("curl")
    fi

    # python3 (HMAC calculation for admin registration)
    if ! command -v python3 &>/dev/null; then
        missing+=("python3")
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        error "The following required tools are missing:"
        for dep in "${missing[@]}"; do
            echo -e "    ${RED}•${RESET} ${dep}"
        done
        echo
        echo "  On Ubuntu/Debian:  sudo apt-get install -y ${missing[*]}"
        echo "  On Fedora/RHEL:    sudo dnf install -y ${missing[*]}"
        echo
        die "Please install the missing dependencies and re-run setup.sh."
    fi

    success "All dependencies satisfied."
}

# =============================================================================
# Step 2 — Interactive configuration
# =============================================================================
gather_config() {
    echo
    echo -e "${BOLD}  Configuration${RESET}"
    echo -e "  ─────────────────────────────────────────────────────"
    echo -e "  Press Enter to accept a ${CYAN}[default]${RESET}.\n"

    # -- Matrix domain --------------------------------------------------------
    ask MATRIX_DOMAIN \
        "Matrix homeserver domain  (e.g. matrix.example.com)" \
        ""
    while [[ -z "$MATRIX_DOMAIN" ]]; do
        warn "Matrix domain is required."
        ask MATRIX_DOMAIN "Matrix homeserver domain" ""
    done

    # -- Server name (for Matrix IDs like @user:example.com) --------------------
    local _suggested_server_name
    _suggested_server_name="$(extract_base_domain "$MATRIX_DOMAIN")"
    ask SERVER_NAME \
        "Matrix server name (used in user IDs: @user:SERVER_NAME)" \
        "$_suggested_server_name"

    # -- Admin credentials ---------------------------------------------------
    echo
    echo -e "  ${BOLD}Admin account${RESET}"
    ask ADMIN_USERNAME "Admin username" "admin"
    while [[ -z "$ADMIN_USERNAME" ]]; do
        warn "Admin username is required."
        ask ADMIN_USERNAME "Admin username" "admin"
    done

    local pw_a pw_b
    while true; do
        ask_secret pw_a "Admin password"
        if [[ ${#pw_a} -lt 10 ]]; then
            warn "Password must be at least 10 characters. Try again."
            continue
        fi
        ask_secret pw_b "Confirm admin password"
        if [[ "$pw_a" != "$pw_b" ]]; then
            warn "Passwords do not match. Try again."
        else
            break
        fi
    done
    ADMIN_PASSWORD="$pw_a"

    # -- Optional features ---------------------------------------------------
    echo
    echo -e "  ${BOLD}Optional features${RESET}"

    ask_yn ENABLE_REGISTRATION_INPUT \
        "Allow public user registration?" \
        "n"
    if [[ "$ENABLE_REGISTRATION_INPUT" == "y" ]]; then
        ENABLE_REGISTRATION="true"
    else
        ENABLE_REGISTRATION="false"
    fi

    ask_yn ENABLE_FEDERATION_INPUT \
        "Enable federation with other Matrix servers?" \
        "y"
    if [[ "$ENABLE_FEDERATION_INPUT" == "y" ]]; then
        FEDERATION_WHITELIST="~"        # YAML null → no whitelist = open federation
        ALLOW_PUBLIC_ROOMS_FEDERATION="true"
    else
        # Prevent any cross-server federation
        FEDERATION_WHITELIST="[]"
        ALLOW_PUBLIC_ROOMS_FEDERATION="false"
    fi

    # -- Confirm summary -----------------------------------------------------
    echo
    echo -e "${BOLD}  Configuration summary${RESET}"
    echo -e "  ─────────────────────────────────────────────────────"
    echo -e "  Matrix domain   : ${CYAN}${MATRIX_DOMAIN}${RESET}"
    echo -e "  Server name     : ${CYAN}${SERVER_NAME}${RESET}  (IDs look like @${ADMIN_USERNAME}:${SERVER_NAME})"
    echo -e "  Admin user      : ${CYAN}${ADMIN_USERNAME}${RESET}"
    echo -e "  Public reg.     : ${CYAN}${ENABLE_REGISTRATION}${RESET}"
    echo -e "  Federation      : ${CYAN}${ENABLE_FEDERATION_INPUT}${RESET}"
    echo

    ask_yn _confirm "Does this look right? Proceed?" "y"
    if [[ "$_confirm" != "y" ]]; then
        warn "Restarting configuration…"
        echo
        gather_config
    fi
}

# =============================================================================
# Step 3 — Generate secrets & render config files
# =============================================================================
generate_config() {
    info "Generating secrets…"

    POSTGRES_PASSWORD="$(generate_secret)"
    REGISTRATION_SHARED_SECRET="$(generate_secret)"
    MACAROON_SECRET_KEY="$(generate_secret)"
    FORM_SECRET="$(generate_secret)"

    success "Secrets generated."

    # -- Write .env -----------------------------------------------------------
    info "Writing ${DEPLOY_ENV}…"
    cat > "$DEPLOY_ENV" <<EOF
# matrix-easy-deploy environment
# Generated by setup.sh on $(date -u +"%Y-%m-%d %H:%M UTC")
# Keep this file private — it contains secrets.

MATRIX_DOMAIN=${MATRIX_DOMAIN}
SERVER_NAME=${SERVER_NAME}
ADMIN_USERNAME=${ADMIN_USERNAME}

POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
REGISTRATION_SHARED_SECRET=${REGISTRATION_SHARED_SECRET}
MACAROON_SECRET_KEY=${MACAROON_SECRET_KEY}
FORM_SECRET=${FORM_SECRET}

ENABLE_REGISTRATION=${ENABLE_REGISTRATION}
EOF
    chmod 600 "$DEPLOY_ENV"
    success ".env written."

    # -- Build substitution map -----------------------------------------------
    local vars_file
    vars_file="$(mktemp)"
    trap 'rm -f "$vars_file"' EXIT

    cat > "$vars_file" <<EOF
MATRIX_DOMAIN=${MATRIX_DOMAIN}
SERVER_NAME=${SERVER_NAME}
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
REGISTRATION_SHARED_SECRET=${REGISTRATION_SHARED_SECRET}
MACAROON_SECRET_KEY=${MACAROON_SECRET_KEY}
FORM_SECRET=${FORM_SECRET}
ENABLE_REGISTRATION=${ENABLE_REGISTRATION}
FEDERATION_WHITELIST=${FEDERATION_WHITELIST}
ALLOW_PUBLIC_ROOMS_FEDERATION=${ALLOW_PUBLIC_ROOMS_FEDERATION}
EOF

    # -- Caddyfile -------------------------------------------------------------
    info "Rendering Caddyfile…"
    render_template \
        "${SCRIPT_DIR}/caddy/Caddyfile.template" \
        "${SCRIPT_DIR}/caddy/Caddyfile" \
        "$vars_file"
    success "caddy/Caddyfile written."

    # -- Synapse homeserver.yaml -----------------------------------------------
    info "Rendering homeserver.yaml…"
    render_template \
        "${SCRIPT_DIR}/modules/core/synapse/homeserver.yaml.template" \
        "${SCRIPT_DIR}/modules/core/synapse/homeserver.yaml" \
        "$vars_file"
    success "modules/core/synapse/homeserver.yaml written."

    # -- Element config.json ---------------------------------------------------
    info "Rendering element/config.json…"
    render_template \
        "${SCRIPT_DIR}/modules/core/element/config.json.template" \
        "${SCRIPT_DIR}/modules/core/element/config.json" \
        "$vars_file"
    success "modules/core/element/config.json written."
}

# =============================================================================
# Step 4 — Docker infrastructure
# =============================================================================
setup_docker() {
    info "Setting up Docker infrastructure…"

    ensure_docker_network "caddy_net"
    ensure_docker_volume  "caddy_data"

    success "Docker infrastructure ready."
}

# =============================================================================
# Step 5 — Start services
# =============================================================================
start_services() {
    echo
    info "Starting Caddy…"
    (cd "${SCRIPT_DIR}/caddy" && $DOCKER_COMPOSE up -d --pull always)
    success "Caddy is up."

    echo
    info "Starting core Matrix services (PostgreSQL + Synapse + Element)…"
    info "  Pulling images — this may take a few minutes on first run."
    (
        cd "${SCRIPT_DIR}/modules/core"
        # Pass the generated postgres password via environment
        POSTGRES_PASSWORD="$POSTGRES_PASSWORD" \
            $DOCKER_COMPOSE up -d --pull always
    )
    success "Core services started."
}

# =============================================================================
# Step 6 — Wait for Synapse and create admin user
# =============================================================================
setup_admin() {
    local synapse_url="https://${MATRIX_DOMAIN}"

    echo
    info "Waiting for Synapse to finish starting…"
    echo -e "  ${CYAN}(This usually takes 20–60 s on first boot while the database is initialised.)${RESET}"

    # Poll the Synapse health endpoint
    local attempt=0
    local max=40
    until curl -fsSL --max-time 5 \
        "https://${MATRIX_DOMAIN}/_matrix/client/versions" &>/dev/null; do
        attempt=$((attempt + 1))
        if [[ $attempt -ge $max ]]; then
            warn "Synapse hasn't responded after $((max * 5))s."
            warn "It may still be starting. You can create the admin user later:"
            echo
            echo -e "  ${CYAN}bash scripts/create-admin.sh \\"
            echo -e "      https://${MATRIX_DOMAIN} \\"
            echo -e "      <registration_shared_secret> \\"
            echo -e "      ${ADMIN_USERNAME} \\"
            echo -e "      <your_password>${RESET}"
            echo
            return 0
        fi
        printf "    %ds elapsed…\r" $((attempt * 5))
        sleep 5
    done
    echo
    success "Synapse is responding."

    # Create the admin user
    echo
    info "Creating admin user '@${ADMIN_USERNAME}:${SERVER_NAME}'…"
    bash "${SCRIPT_DIR}/scripts/create-admin.sh" \
        "https://${MATRIX_DOMAIN}" \
        "${REGISTRATION_SHARED_SECRET}" \
        "${ADMIN_USERNAME}" \
        "${ADMIN_PASSWORD}"
}

# =============================================================================
# Step 7 — Success summary
# =============================================================================
print_summary() {
    echo
    echo -e "${GREEN}${BOLD}"
    cat << 'EOF'
  ┌─────────────────────────────────────────────────────┐
  │                                                     │
  │              Setup complete!                        │
  │                                                     │
  └─────────────────────────────────────────────────────┘
EOF
    echo -e "${RESET}"
    echo -e "  Your Matrix server is live. Here's where everything lives:\n"
    echo -e "  ${BOLD}Matrix homeserver${RESET}  https://${MATRIX_DOMAIN}/"
    echo -e "  ${BOLD}Element client${RESET}     https://${MATRIX_DOMAIN}/"
    echo -e "  ${BOLD}Synapse admin${RESET}      https://${MATRIX_DOMAIN}/_synapse/admin/v1/"
    echo
    echo -e "  ${BOLD}Your admin ID${RESET}      @${ADMIN_USERNAME}:${SERVER_NAME}"
    echo
    echo -e "  ${BOLD}Useful commands${RESET}"
    echo -e "    See logs (Synapse):     ${CYAN}docker logs -f matrix_synapse${RESET}"
    echo -e "    See logs (Caddy):       ${CYAN}docker logs -f caddy${RESET}"
    echo -e "    Stop all services:      ${CYAN}bash stop.sh${RESET}"
    echo -e "    Restart all services:   ${CYAN}bash start.sh${RESET}"
    echo
    echo -e "  ${BOLD}Add a bridge or bot later${RESET}"
    echo -e "    ${CYAN}bash setup.sh --module <module-name>${RESET}"
    echo
    echo -e "  Secrets are stored in ${CYAN}.env${RESET} — keep it private."
    echo
}

# =============================================================================
# Module subcommand dispatcher (extensibility hook)
# =============================================================================
run_module_setup() {
    local module="$1"
    local module_script="${SCRIPT_DIR}/modules/${module}/setup.sh"

    if [[ ! -f "$module_script" ]]; then
        die "Module '${module}' not found. Expected: ${module_script}"
    fi

    info "Running setup for module: ${module}"
    # shellcheck disable=SC1090
    bash "$module_script"
}

# =============================================================================
# Entry point
# =============================================================================
main() {
    # Parse flags
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
