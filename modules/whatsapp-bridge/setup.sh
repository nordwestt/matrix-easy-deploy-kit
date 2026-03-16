#!/usr/bin/env bash
# =============================================================================
#  matrix-easy-deploy  —  modules/whatsapp-bridge/setup.sh
#  Sets up the mautrix-whatsapp bridge as an appservice on Synapse.
#
#  Run via:  bash matrix-wizard.sh --module whatsapp-bridge
#
#  What this does:
#    1. Reads the existing .env to discover homeserver details.
#    2. Asks for bridge admin username and relay-mode preference.
#    3. Creates a dedicated PostgreSQL database for the bridge.
#    4. Pulls the bridge image and lets it generate a starter config.yaml.
#    5. Patches config.yaml with mandatory fields (homeserver, DB, permissions).
#    6. Runs the bridge container once more to generate registration.yaml.
#    7. Registers the appservice with Synapse (via homeserver.yaml).
#    8. Starts the bridge container and restarts Synapse.
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck source=../../scripts/lib.sh
source "${PROJECT_ROOT}/scripts/lib.sh"

IFS=' ' read -ra DOCKER_COMPOSE <<< "$(docker_compose_cmd)"

DEPLOY_ENV="${PROJECT_ROOT}/.env"
MODULE_DIR="${SCRIPT_DIR}"
BRIDGE_DATA_DIR="${MODULE_DIR}/whatsapp"
CORE_SYNAPSE_DATA_DIR="${PROJECT_ROOT}/modules/core/synapse_data"
HOMESERVER_YAML="${PROJECT_ROOT}/modules/core/synapse/homeserver.yaml"
CADDYFILE="${PROJECT_ROOT}/caddy/Caddyfile"

BRIDGE_IMAGE="dock.mau.dev/mautrix/whatsapp:latest"
BRIDGE_CONTAINER="mautrix-whatsapp"
BRIDGE_PORT="29318"

# =============================================================================
# Step 1 — Load existing deployment environment
# =============================================================================
load_env() {
    if [[ ! -f "$DEPLOY_ENV" ]]; then
        die "No .env file found at ${DEPLOY_ENV}. Please run the main setup wizard first."
    fi

    info "Loading existing deployment configuration from .env…"
    while IFS='=' read -r key value; do
        [[ -z "$key" || "$key" == \#* ]] && continue
        # strip inline comments
        value="${value%%#*}"
        value="${value%"${value##*[![:space:]]}"}"
        export "${key}=${value}"
    done < "$DEPLOY_ENV"

    local required_vars=(MATRIX_DOMAIN SERVER_NAME)
    for var in "${required_vars[@]}"; do
        if [[ -z "${!var:-}" ]]; then
            die "Required variable '${var}' not found in .env. Please re-run the main wizard."
        fi
    done

    # Derive a sensible default admin username from .env if available
    ADMIN_USERNAME="${ADMIN_USERNAME:-admin}"

    success "Loaded: MATRIX_DOMAIN=${MATRIX_DOMAIN}, SERVER_NAME=${SERVER_NAME}"
}

# =============================================================================
# Step 2 — Verify SERVER_NAME matches Synapse's actual server_name
# =============================================================================
verify_server_name() {
    if [[ ! -f "$HOMESERVER_YAML" ]]; then
        warn "homeserver.yaml not found — skipping server_name cross-check."
        return
    fi

    local actual_server_name
    actual_server_name="$(grep -E '^server_name:' "$HOMESERVER_YAML" \
        | head -1 | awk '{print $2}' | tr -d '"')"

    if [[ -z "$actual_server_name" ]]; then
        warn "Could not read server_name from homeserver.yaml — skipping check."
        return
    fi

    if [[ "$actual_server_name" == "$SERVER_NAME" ]]; then
        success "server_name check passed: ${SERVER_NAME}"
        return
    fi

    echo
    warn "SERVER_NAME mismatch detected!"
    echo -e "  ${BOLD}.env has:${RESET}             ${RED}${SERVER_NAME}${RESET}"
    echo -e "  ${BOLD}homeserver.yaml has:${RESET}  ${GREEN}${actual_server_name}${RESET}"
    echo -e "  Using homeserver.yaml value for this module setup."
    echo

    SERVER_NAME="$actual_server_name"
    export SERVER_NAME
    info "Using server_name=${SERVER_NAME} for bridge config."
}

# =============================================================================
# Step 3 — Gather configuration from the user
# =============================================================================
gather_config() {
    echo
    echo -e "${BOLD}  WhatsApp Bridge Configuration${RESET}"
    echo -e "  ─────────────────────────────────────────────────────"
    echo -e "  mautrix-whatsapp bridges your Matrix account to WhatsApp."
    echo -e "  After setup you scan a QR code to link your WhatsApp account."
    echo -e "  Press Enter to accept a ${CYAN}[default]${RESET}.\n"

    # Admin user on the homeserver
    ask WA_ADMIN_USERNAME \
        "Matrix admin username for full bridge access (without @/server part)" \
        "${ADMIN_USERNAME:-admin}"
    while [[ -z "$WA_ADMIN_USERNAME" ]]; do
        warn "Admin username is required."
        ask WA_ADMIN_USERNAME "Matrix admin username" "${ADMIN_USERNAME:-admin}"
    done

    # Relay mode — allows non-logged-in users to send messages via a logged-in relaybot
    ask_yn WA_RELAY_ENABLED \
        "Enable relay mode? (lets non-logged-in users send messages via a relaybot)" \
        "n"

    # Database name for the bridge
    ask WA_DB_NAME \
        "PostgreSQL database name for the WhatsApp bridge" \
        "mautrix_whatsapp"

    echo
    echo -e "${BOLD}  Configuration summary${RESET}"
    echo -e "  ─────────────────────────────────────────────────────"
    echo -e "  Homeserver      : ${CYAN}${MATRIX_DOMAIN}${RESET}"
    echo -e "  Server name     : ${CYAN}${SERVER_NAME}${RESET}"
    echo -e "  Bridge admin    : ${CYAN}@${WA_ADMIN_USERNAME}:${SERVER_NAME}${RESET}"
    echo -e "  Relay mode      : ${CYAN}${WA_RELAY_ENABLED}${RESET}"
    echo -e "  Database name   : ${CYAN}${WA_DB_NAME}${RESET}"
    echo

    ask_yn _confirm "Does this look right? Proceed?" "y"
    if [[ "$_confirm" != "y" ]]; then
        warn "Restarting configuration…"
        echo
        gather_config
    fi
}

# =============================================================================
# Step 4 — Create a dedicated PostgreSQL database for the bridge
# =============================================================================
setup_database() {
    info "Setting up PostgreSQL database '${WA_DB_NAME}' for the WhatsApp bridge…"

    if [[ -z "${POSTGRES_PASSWORD:-}" ]]; then
        die "POSTGRES_PASSWORD not found in .env. Please re-run the main wizard."
    fi

    # Generate a dedicated bridge DB user + password
    WA_DB_USER="mautrix_whatsapp"
    WA_DB_PASSWORD="$(generate_secret)"
    WA_DB_URI="postgres://${WA_DB_USER}:${WA_DB_PASSWORD}@matrix_postgres/${WA_DB_NAME}?sslmode=disable"
    export WA_DB_USER WA_DB_PASSWORD WA_DB_URI

    if ! docker ps --format '{{.Names}}' | grep -q '^matrix_postgres$'; then
        die "matrix_postgres is not running. Please start the core stack first."
    fi

    # Create the role (ignore error if already exists)
    docker exec -e PGPASSWORD="${POSTGRES_PASSWORD}" matrix_postgres \
        psql -U synapse -c \
        "DO \$\$ BEGIN
           IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = '${WA_DB_USER}') THEN
             CREATE ROLE ${WA_DB_USER} LOGIN PASSWORD '${WA_DB_PASSWORD}';
           ELSE
             ALTER ROLE ${WA_DB_USER} WITH PASSWORD '${WA_DB_PASSWORD}';
           END IF;
         END \$\$;" \
        2>&1 | sed 's/^/    /'

    # Create the database (ignore error if already exists)
    docker exec -e PGPASSWORD="${POSTGRES_PASSWORD}" matrix_postgres \
        psql -U synapse -tc \
        "SELECT 1 FROM pg_database WHERE datname='${WA_DB_NAME}'" | grep -q 1 \
        || docker exec -e PGPASSWORD="${POSTGRES_PASSWORD}" matrix_postgres \
           psql -U synapse -c \
           "CREATE DATABASE ${WA_DB_NAME} OWNER ${WA_DB_USER}
            ENCODING 'UTF8' LC_COLLATE='C' LC_CTYPE='C'
            TEMPLATE template0;" \
           2>&1 | sed 's/^/    /'

    # Grant privileges
    docker exec -e PGPASSWORD="${POSTGRES_PASSWORD}" matrix_postgres \
        psql -U synapse -c \
        "GRANT ALL PRIVILEGES ON DATABASE ${WA_DB_NAME} TO ${WA_DB_USER};" \
        2>&1 | sed 's/^/    /'

    success "Database '${WA_DB_NAME}' ready."
}

# =============================================================================
# Step 5 — Pull image, auto-generate config.yaml, patch mandatory fields
# =============================================================================
generate_config() {
    mkdir -p "$BRIDGE_DATA_DIR"

    local config_file="${BRIDGE_DATA_DIR}/config.yaml"

    # --- Pull the image ---
    info "Pulling mautrix-whatsapp image (${BRIDGE_IMAGE})…"
    docker pull "$BRIDGE_IMAGE" 2>&1 | tail -5 | sed 's/^/    /'
    success "Image pulled."

    # --- Let the container generate a starter config.yaml ---
    if [[ -f "$config_file" ]]; then
        info "config.yaml already exists — skipping auto-generation."
        info "Patching mandatory fields in existing config.yaml…"
    else
        info "Running container once to generate config.yaml…"
        docker run --rm \
            -v "${BRIDGE_DATA_DIR}:/data:z" \
            "$BRIDGE_IMAGE" \
            2>&1 | sed 's/^/    /' || true
        # The container exits after writing config.yaml
        if [[ ! -f "$config_file" ]]; then
            die "config.yaml was not generated. Check Docker output above."
        fi
        success "config.yaml generated."
    fi

    # --- Patch mandatory fields using Python ---
    info "Patching config.yaml with homeserver, database, and permissions…"

    python3 - "$config_file" \
        "$SERVER_NAME" \
        "http://matrix_synapse:8008" \
        "http://${BRIDGE_CONTAINER}:${BRIDGE_PORT}" \
        "postgres" \
        "$WA_DB_URI" \
        "$WA_ADMIN_USERNAME" \
        "$WA_RELAY_ENABLED" <<'PYEOF'
import sys, re

config_path   = sys.argv[1]
server_name   = sys.argv[2]
hs_address    = sys.argv[3]
as_address    = sys.argv[4]
db_type       = sys.argv[5]
db_uri        = sys.argv[6]
admin_user    = sys.argv[7]
relay_enabled = sys.argv[8].lower() == "y"

with open(config_path, 'r') as f:
    content = f.read()

def replace_field(text, key_path, new_value, quote=True):
    """Replace a YAML scalar field matched by its last key name (handles nested indents)."""
    key = key_path.split('.')[-1]
    quoted_val = f'"{new_value}"' if quote else new_value
    # Match lines like:   key: anything  (with optional trailing comment)
    pattern = rf'^(\s*{re.escape(key)}:)\s*.*$'
    replacement = rf'\1 {quoted_val}'
    result, n = re.subn(pattern, replacement, text, count=1, flags=re.MULTILINE)
    if n == 0:
        print(f"  [warn] Field '{key}' not found in config — skipping.", file=sys.stderr)
    return result

# homeserver section
content = replace_field(content, 'homeserver.domain',  server_name)
content = replace_field(content, 'homeserver.address', hs_address)

# appservice address (what Synapse uses to reach the bridge)
content = replace_field(content, 'appservice.address', as_address)

# database
content = replace_field(content, 'database.type', db_type)
content = replace_field(content, 'database.uri',  db_uri)

# permissions block — find it wherever it lives (top-level or nested under bridge:)
# Detect the indentation of the permissions: key so we can match its child lines.
perm_match = re.search(r'^( *)permissions:\s*\n((?:(?! *\S)|\1 [^\n]*\n)*)', content, re.MULTILINE)
if perm_match:
    indent = perm_match.group(1)          # e.g. "" or "    "
    child_indent = indent + "    "        # one level deeper
    relay_line = f'{child_indent}"*": relay' if relay_enabled else f'{child_indent}# "*": relay  # uncomment to enable relay mode'
    new_block = (
        f'{indent}permissions:\n'
        f'{relay_line}\n'
        f'{child_indent}"{server_name}": user\n'
        f'{child_indent}"@{admin_user}:{server_name}": admin\n'
    )
    content = content[:perm_match.start()] + new_block + content[perm_match.end():]
else:
    # No permissions block at all — append one under bridge: if present, else top-level
    child_indent = "    "
    relay_line = f'{child_indent}"*": relay' if relay_enabled else f'{child_indent}# "*": relay  # uncomment to enable relay mode'
    new_block = (
        f'  permissions:\n'
        f'{relay_line}\n'
        f'{child_indent}"{server_name}": user\n'
        f'{child_indent}"@{admin_user}:{server_name}": admin\n'
    )
    bridge_match = re.search(r'^bridge:\s*$', content, re.MULTILINE)
    if bridge_match:
        insert_pos = content.index('\n', bridge_match.start()) + 1
        content = content[:insert_pos] + new_block + content[insert_pos:]
    else:
        content += f'\nbridge:\n{new_block}'
    print("  [warn] permissions block not found — injected under bridge:", file=sys.stderr)

with open(config_path, 'w') as f:
    f.write(content)

print("  config.yaml patched successfully.")
PYEOF

    success "config.yaml patched."

    # --- Append bridge vars to .env ---
    if ! grep -q "^WA_DB_NAME=" "$DEPLOY_ENV"; then
        info "Appending WhatsApp bridge variables to .env…"
        cat >> "$DEPLOY_ENV" <<EOF

# WhatsApp bridge module — added by modules/whatsapp-bridge/setup.sh
WA_DB_NAME=${WA_DB_NAME}
WA_DB_USER=${WA_DB_USER}
WA_DB_PASSWORD=${WA_DB_PASSWORD}
WA_DB_URI=${WA_DB_URI}
WA_ADMIN_USERNAME=${WA_ADMIN_USERNAME}
EOF
        success ".env updated."
    else
        info "WhatsApp bridge variables already in .env — skipping."
    fi
}

# =============================================================================
# Step 6 — Generate registration.yaml
# =============================================================================
generate_registration() {
    local reg_file="${BRIDGE_DATA_DIR}/registration.yaml"

    if [[ -f "$reg_file" ]]; then
        info "registration.yaml already exists — skipping generation."
        return
    fi

    info "Running container to generate registration.yaml…"
    docker run --rm \
        -v "${BRIDGE_DATA_DIR}:/data:z" \
        "$BRIDGE_IMAGE" \
        2>&1 | sed 's/^/    /' || true

    if [[ ! -f "$reg_file" ]]; then
        die "registration.yaml was not generated. Check config.yaml for errors."
    fi
    success "registration.yaml generated."
}

# =============================================================================
# Step 7 — Register the appservice with Synapse
# =============================================================================
register_appservice() {
    local reg_src="${BRIDGE_DATA_DIR}/registration.yaml"
    local reg_dest="${CORE_SYNAPSE_DATA_DIR}/whatsapp-registration.yaml"
    local reg_container_path="/data/whatsapp-registration.yaml"

    info "Copying registration.yaml to Synapse data directory…"
    cp "$reg_src" "$reg_dest"
    chmod 644 "$reg_dest"
    success "Copied to ${reg_dest}."

    if [[ ! -f "$HOMESERVER_YAML" ]]; then
        die "homeserver.yaml not found at ${HOMESERVER_YAML}."
    fi

    if grep -qF "$reg_container_path" "$HOMESERVER_YAML"; then
        info "WhatsApp bridge already registered in homeserver.yaml — skipping."
        return
    fi

    info "Registering WhatsApp appservice in homeserver.yaml…"
    python3 - "$HOMESERVER_YAML" "$reg_container_path" <<'PYEOF'
import sys, re

filepath = sys.argv[1]
reg_path = sys.argv[2]

with open(filepath, 'r') as f:
    content = f.read()

if 'app_service_config_files' in content:
    content = re.sub(
        r'(app_service_config_files:(?:\s*\n\s+-[^\n]*)*)',
        lambda m: m.group(0) + f'\n  - {reg_path}',
        content,
        count=1
    )
else:
    content += f'\n# Application services (bridges)\napp_service_config_files:\n  - {reg_path}\n'

with open(filepath, 'w') as f:
    f.write(content)

print(f"  Added {reg_path} to app_service_config_files.")
PYEOF
    success "homeserver.yaml updated."
}

# =============================================================================
# Step 8 — Start the bridge and restart Synapse
# =============================================================================
start_services() {
    echo
    info "Starting mautrix-whatsapp…"
    (cd "$MODULE_DIR" && "${DOCKER_COMPOSE[@]}" up -d --pull always)
    success "mautrix-whatsapp started."

    echo
    info "Restarting Synapse to load the new appservice registration…"
    if docker ps --format '{{.Names}}' | grep -q '^matrix_synapse$'; then
        docker restart matrix_synapse
        success "Synapse restarted."
    else
        warn "Synapse (matrix_synapse) is not running."
        warn "Start the core stack first: cd ${PROJECT_ROOT}/modules/core && docker compose up -d"
    fi
}

# =============================================================================
# Summary
# =============================================================================
print_summary() {
    echo
    echo -e "${GREEN}${BOLD}"
    cat << 'EOF'
  ┌─────────────────────────────────────────────────────┐
  │                                                     │
  │   WhatsApp Bridge installed!                        │
  │                                                     │
  └─────────────────────────────────────────────────────┘
EOF
    echo -e "${RESET}"
    echo -e "  ${BOLD}How to link your WhatsApp account${RESET}"
    echo -e "  ─────────────────────────────────────────────────────"
    echo -e "  1. In Element (or any Matrix client), open a DM with:"
    echo -e "     ${CYAN}@whatsappbot:${SERVER_NAME}${RESET}"
    echo -e "  2. Send: ${CYAN}login${RESET}"
    echo -e "  3. The bot will display a QR code."
    echo -e "  4. Open WhatsApp on your phone → Linked Devices → Link a Device."
    echo -e "  5. Scan the QR code. Your chats will start appearing as Matrix rooms.\n"
    echo -e "  ${BOLD}Bridge admin${RESET}        @${WA_ADMIN_USERNAME}:${SERVER_NAME}"
    echo -e "  ${BOLD}Bot username${RESET}         @whatsappbot:${SERVER_NAME}"
    echo -e "  ${BOLD}Relay mode${RESET}           ${WA_RELAY_ENABLED}\n"
    echo -e "  ${BOLD}Useful commands${RESET}"
    echo -e "    Logs:     ${CYAN}docker logs -f mautrix-whatsapp${RESET}"
    echo -e "    Restart:  ${CYAN}docker restart mautrix-whatsapp${RESET}"
    echo -e "    Stop:     ${CYAN}cd ${MODULE_DIR} && docker compose down${RESET}"
    echo -e "    Re-setup: ${CYAN}bash matrix-wizard.sh --module whatsapp-bridge${RESET}"
    echo
    echo -e "  ${BOLD}Files${RESET}"
    echo -e "    Config:       ${CYAN}modules/whatsapp-bridge/whatsapp/config.yaml${RESET}"
    echo -e "    Registration: ${CYAN}modules/whatsapp-bridge/whatsapp/registration.yaml${RESET}"
    echo
    echo -e "  ${YELLOW}Note:${RESET} A WhatsApp mobile app must stay active and connected."
    echo -e "  If you log out or reinstall WhatsApp, run ${CYAN}login${RESET} in the bridge DM again."
    echo
}

# =============================================================================
# Main
# =============================================================================
main() {
    echo
    echo -e "${BOLD}${CYAN}"
    cat << 'EOF'
  ┌────────────────────────────────────────────────────┐
  │                                                    │
  │   WhatsApp Bridge Setup                            │
  │   Powered by mautrix-whatsapp                      │
  │                                                    │
  └────────────────────────────────────────────────────┘
EOF
    echo -e "${RESET}"

    echo -e "${BOLD}  Step 1 of 7 — Load existing configuration${RESET}"
    load_env

    echo
    echo -e "${BOLD}  Step 2 of 7 — Verify server_name consistency${RESET}"
    verify_server_name

    echo
    echo -e "${BOLD}  Step 3 of 7 — Bridge configuration${RESET}"
    gather_config

    echo
    echo -e "${BOLD}  Step 4 of 7 — PostgreSQL database${RESET}"
    setup_database

    echo
    echo -e "${BOLD}  Step 5 of 7 — Generating bridge config${RESET}"
    generate_config

    echo
    echo -e "${BOLD}  Step 6 of 7 — Generating appservice registration${RESET}"
    generate_registration

    echo
    echo -e "${BOLD}  Step 6 of 7 — Registering appservice with Synapse${RESET}"
    register_appservice

    echo
    echo -e "${BOLD}  Step 7 of 7 — Starting services${RESET}"
    start_services

    print_summary
}

main "$@"
