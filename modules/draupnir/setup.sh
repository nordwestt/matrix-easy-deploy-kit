#!/usr/bin/env bash
# =============================================================================
#  matrix-easy-deploy  —  modules/draupnir/setup.sh
#  Sets up Draupnir moderation bot on an existing Matrix deployment.
#
#  Run via:  bash setup.sh --module draupnir
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
DRAUPNIR_DIR="${MODULE_DIR}/draupnir"
HOMESERVER_YAML="${PROJECT_ROOT}/modules/core/synapse/homeserver.yaml"

VARS_FILE=""
cleanup() { [[ -n "$VARS_FILE" ]] && rm -f "$VARS_FILE"; }
trap cleanup EXIT

# =============================================================================
# Step 1 — Load existing deployment environment
# =============================================================================
load_env() {
    if [[ ! -f "$DEPLOY_ENV" ]]; then
        die "No .env file found at ${DEPLOY_ENV}. Please run setup.sh first."
    fi

    info "Loading existing deployment configuration from .env…"
    while IFS='=' read -r key value; do
        [[ -z "$key" || "$key" == \#* ]] && continue
        export "${key}=${value}"
    done < "$DEPLOY_ENV"

    local required_vars=(MATRIX_DOMAIN SERVER_NAME)
    for var in "${required_vars[@]}"; do
        if [[ -z "${!var:-}" ]]; then
            die "Required variable '${var}' not found in .env. Please re-run setup.sh."
        fi
    done

    success "Loaded: MATRIX_DOMAIN=${MATRIX_DOMAIN}, SERVER_NAME=${SERVER_NAME}"
}

# =============================================================================
# Step 2 — Gather module config
# =============================================================================
gather_config() {
    echo
    echo -e "${BOLD}  Draupnir Module Configuration${RESET}"
    echo -e "  ─────────────────────────────────────────────────────"
    echo -e "  Draupnir is a moderation bot for room and policy-list enforcement."
    echo -e "  Press Enter to accept a ${CYAN}[default]${RESET}.\n"

    local _suggested_bot_mxid
    _suggested_bot_mxid="@draupnir:${SERVER_NAME}"
    ask DRAUPNIR_BOT_MXID \
        "Draupnir bot MXID  (create this account first)" \
        "$_suggested_bot_mxid"
    if [[ "$DRAUPNIR_BOT_MXID" == "" ]]; then
        DRAUPNIR_BOT_MXID="$_suggested_bot_mxid"
    fi

    while [[ -z "$DRAUPNIR_BOT_MXID" ]]; do
        warn "Bot MXID is required."
        ask DRAUPNIR_BOT_MXID "Draupnir bot MXID" "$_suggested_bot_mxid"
    done

    while true; do
        ask_secret DRAUPNIR_ACCESS_TOKEN "Draupnir access token"
        if [[ -z "$DRAUPNIR_ACCESS_TOKEN" ]]; then
            warn "Access token is required."
        else
            break
        fi
    done

    local _suggested_management_room
    _suggested_management_room="#draupnir:${SERVER_NAME}"
    ask DRAUPNIR_MANAGEMENT_ROOM \
        "Management room alias or room ID (recommended: unencrypted private room)" \
        "$_suggested_management_room"
    while [[ -z "$DRAUPNIR_MANAGEMENT_ROOM" ]]; do
        warn "Management room is required."
        ask DRAUPNIR_MANAGEMENT_ROOM "Management room alias or room ID" "$_suggested_management_room"
    done

    local _suggested_admin
    if [[ -n "${ADMIN_USERNAME:-}" ]]; then
        _suggested_admin="@${ADMIN_USERNAME}:${SERVER_NAME}"
    else
        _suggested_admin="@admin:${SERVER_NAME}"
    fi
    ask DRAUPNIR_ADMIN_MXID "Admin MXID (Draupnir controller)" "$_suggested_admin"
    while [[ -z "$DRAUPNIR_ADMIN_MXID" ]]; do
        warn "Admin MXID is required."
        ask DRAUPNIR_ADMIN_MXID "Admin MXID (Draupnir controller)" "$_suggested_admin"
    done

    ask DRAUPNIR_PROTECTED_ROOMS_CSV \
        "Protected room aliases/IDs (comma-separated, optional)" \
        ""

    ask_yn ENABLE_DRAUPNIR_SYNAPSE_HTTP_ANTISPAM_INPUT \
        "Enable Synapse synapse-http-antispam wiring now?" \
        "n"

    if [[ "$ENABLE_DRAUPNIR_SYNAPSE_HTTP_ANTISPAM_INPUT" == "y" ]]; then
        DRAUPNIR_ENABLE_SYNAPSE_HTTP_ANTISPAM="true"
        ask DRAUPNIR_ANTISPAM_TOKEN \
            "Antispam authorization token" \
            "$(generate_secret)"
        while [[ -z "$DRAUPNIR_ANTISPAM_TOKEN" ]]; do
            warn "Antispam authorization token is required when antispam is enabled."
            ask DRAUPNIR_ANTISPAM_TOKEN "Antispam authorization token" "$(generate_secret)"
        done
    else
        DRAUPNIR_ENABLE_SYNAPSE_HTTP_ANTISPAM="false"
        DRAUPNIR_ANTISPAM_TOKEN=""
    fi

    echo
    echo -e "${BOLD}  Configuration summary${RESET}"
    echo -e "  ─────────────────────────────────────────────────────"
    echo -e "  Homeserver URL     : ${CYAN}https://${MATRIX_DOMAIN}${RESET}"
    echo -e "  Bot MXID           : ${CYAN}${DRAUPNIR_BOT_MXID}${RESET}"
    echo -e "  Management room    : ${CYAN}${DRAUPNIR_MANAGEMENT_ROOM}${RESET}"
    echo -e "  Admin MXID         : ${CYAN}${DRAUPNIR_ADMIN_MXID}${RESET}"
    if [[ -n "$DRAUPNIR_PROTECTED_ROOMS_CSV" ]]; then
        echo -e "  Protected rooms    : ${CYAN}${DRAUPNIR_PROTECTED_ROOMS_CSV}${RESET}"
    else
        echo -e "  Protected rooms    : ${CYAN}(none preconfigured)${RESET}"
    fi
    echo -e "  Synapse antispam   : ${CYAN}${DRAUPNIR_ENABLE_SYNAPSE_HTTP_ANTISPAM}${RESET}"
    echo

    ask_yn _confirm "Does this look right? Proceed?" "y"
    if [[ "$_confirm" != "y" ]]; then
        warn "Restarting configuration…"
        echo
        gather_config
    fi
}

csv_to_yaml_array() {
    local csv="$1"
    python3 - "$csv" <<'PYEOF'
import json
import sys

raw = sys.argv[1]
items = [part.strip() for part in raw.split(',') if part.strip()]
print(json.dumps(items))
PYEOF
}

upsert_env_var() {
    local file="$1"
    local key="$2"
    local value="$3"

    python3 - "$file" "$key" "$value" <<'PYEOF'
import sys
from pathlib import Path

path = Path(sys.argv[1])
key = sys.argv[2]
value = sys.argv[3]
line = f"{key}={value}"

if path.exists():
    lines = path.read_text(encoding='utf-8').splitlines()
else:
    lines = []

for idx, existing in enumerate(lines):
    if existing.startswith(f"{key}="):
        lines[idx] = line
        break
else:
    lines.append(line)

path.write_text("\n".join(lines) + "\n", encoding='utf-8')
PYEOF
}

# =============================================================================
# Step 3 — Persist module env + render config
# =============================================================================
generate_config() {
    info "Preparing Draupnir data directories…"
    mkdir -p "${DRAUPNIR_DIR}/config"
    success "Data directories ready."

    DRAUPNIR_PROTECTED_ROOMS_YAML="$(csv_to_yaml_array "$DRAUPNIR_PROTECTED_ROOMS_CSV")"

    info "Updating .env with Draupnir settings…"
    upsert_env_var "$DEPLOY_ENV" "DRAUPNIR_BOT_MXID" "$DRAUPNIR_BOT_MXID"
    upsert_env_var "$DEPLOY_ENV" "DRAUPNIR_MANAGEMENT_ROOM" "$DRAUPNIR_MANAGEMENT_ROOM"
    upsert_env_var "$DEPLOY_ENV" "DRAUPNIR_ADMIN_MXID" "$DRAUPNIR_ADMIN_MXID"
    upsert_env_var "$DEPLOY_ENV" "DRAUPNIR_PROTECTED_ROOMS_CSV" "$DRAUPNIR_PROTECTED_ROOMS_CSV"
    upsert_env_var "$DEPLOY_ENV" "DRAUPNIR_ENABLE_SYNAPSE_HTTP_ANTISPAM" "$DRAUPNIR_ENABLE_SYNAPSE_HTTP_ANTISPAM"
    upsert_env_var "$DEPLOY_ENV" "DRAUPNIR_ANTISPAM_TOKEN" "$DRAUPNIR_ANTISPAM_TOKEN"
    chmod 600 "$DEPLOY_ENV"
    success ".env updated."

    VARS_FILE="$(mktemp)"
    cat > "$VARS_FILE" <<EOF
MATRIX_DOMAIN=${MATRIX_DOMAIN}
DRAUPNIR_ACCESS_TOKEN=${DRAUPNIR_ACCESS_TOKEN}
DRAUPNIR_MANAGEMENT_ROOM=${DRAUPNIR_MANAGEMENT_ROOM}
DRAUPNIR_PROTECTED_ROOMS_YAML=${DRAUPNIR_PROTECTED_ROOMS_YAML}
DRAUPNIR_ADMIN_MXID=${DRAUPNIR_ADMIN_MXID}
DRAUPNIR_ENABLE_SYNAPSE_HTTP_ANTISPAM=${DRAUPNIR_ENABLE_SYNAPSE_HTTP_ANTISPAM}
DRAUPNIR_ANTISPAM_TOKEN=${DRAUPNIR_ANTISPAM_TOKEN}
EOF

    info "Rendering draupnir/config/production.yaml…"
    render_template \
        "${DRAUPNIR_DIR}/config/production.yaml.template" \
        "${DRAUPNIR_DIR}/config/production.yaml" \
        "$VARS_FILE"
    chmod 600 "${DRAUPNIR_DIR}/config/production.yaml"
    success "draupnir/config/production.yaml written."
}

# =============================================================================
# Step 4 — Optional Synapse antispam wiring
# =============================================================================
configure_synapse_antispam() {
    if [[ "$DRAUPNIR_ENABLE_SYNAPSE_HTTP_ANTISPAM" != "true" ]]; then
        info "Synapse synapse-http-antispam wiring disabled — skipping."
        return
    fi

    if [[ ! -f "$HOMESERVER_YAML" ]]; then
        die "homeserver.yaml not found at ${HOMESERVER_YAML}. Please run setup.sh first."
    fi

    info "Adding synapse-http-antispam config to homeserver.yaml…"
    python3 - "$HOMESERVER_YAML" "$DRAUPNIR_ANTISPAM_TOKEN" <<'PYEOF'
import sys
from pathlib import Path

path = Path(sys.argv[1])
token = sys.argv[2]
lines = path.read_text(encoding='utf-8').splitlines()

needle = 'synapse_http_antispam.HTTPAntispam'
if any(needle in line for line in lines):
    print('  synapse-http-antispam module already configured — skipping.')
    sys.exit(0)

block = [
    '  - module: synapse_http_antispam.HTTPAntispam',
    '    config:',
    '      base_url: http://matrix-draupnir:8080/api/1/spam_check',
    f'      authorization: {token}',
    '      do_ping: true',
    '      enabled_callbacks:',
    '        - user_may_invite',
    '        - user_may_join_room',
    '      fail_open:',
    '        user_may_invite: true',
    '        user_may_join_room: true',
]

mod_idx = next((i for i, line in enumerate(lines) if line.startswith('modules:')), None)
if mod_idx is None:
    if lines and lines[-1] != '':
        lines.append('')
    lines.append('# Synapse antispam integration (Draupnir)')
    lines.append('modules:')
    lines.extend(block)
else:
    insert_at = mod_idx + 1
    while insert_at < len(lines):
        line = lines[insert_at]
        if line.strip() == '':
            insert_at += 1
            continue
        if not line.startswith('  '):
            break
        insert_at += 1
    lines[insert_at:insert_at] = block

path.write_text('\n'.join(lines) + '\n', encoding='utf-8')
print('  Added synapse_http_antispam.HTTPAntispam module config.')
PYEOF
    success "homeserver.yaml updated."

    warn "synapse-http-antispam must be installed inside the Synapse Python environment."
    warn "If it is not installed, Synapse may fail to start until the module is installed or removed."
    warn "Run: bash scripts/install-synapse-http-antispam.sh"
}

# =============================================================================
# Step 5 — Start services
# =============================================================================
start_services() {
    echo
    info "Starting Draupnir…"
    (cd "$MODULE_DIR" && "${DOCKER_COMPOSE[@]}" up -d --pull always)
    success "Draupnir started."

    if [[ "$DRAUPNIR_ENABLE_SYNAPSE_HTTP_ANTISPAM" == "true" ]]; then
        echo
        info "Restarting Synapse to load antispam module config…"
        if docker ps --format '{{.Names}}' | grep -q '^matrix_synapse$'; then
            docker restart matrix_synapse >/dev/null
            success "Synapse restarted."
        else
            warn "Synapse container (matrix_synapse) is not running."
            warn "Start the core stack first: cd modules/core && docker compose up -d"
        fi
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
  │         Draupnir module installed!                  │
  │                                                     │
  └─────────────────────────────────────────────────────┘
EOF
    echo -e "${RESET}"
    echo -e "  Draupnir is running in bot mode."
    echo
    echo -e "  ${BOLD}Bot MXID${RESET}            ${CYAN}${DRAUPNIR_BOT_MXID}${RESET}"
    echo -e "  ${BOLD}Management room${RESET}     ${CYAN}${DRAUPNIR_MANAGEMENT_ROOM}${RESET}"
    echo -e "  ${BOLD}Config file${RESET}         ${CYAN}modules/draupnir/draupnir/config/production.yaml${RESET}"
    echo
    echo -e "  ${BOLD}Useful commands${RESET}"
    echo -e "    Logs:     ${CYAN}docker logs -f matrix-draupnir${RESET}"
    echo -e "    Restart:  ${CYAN}docker restart matrix-draupnir${RESET}"
    echo -e "    Stop:     ${CYAN}cd modules/draupnir && docker compose down${RESET}"
    if [[ "$DRAUPNIR_ENABLE_SYNAPSE_HTTP_ANTISPAM" == "true" ]]; then
        echo -e "    Install Synapse antispam module: ${CYAN}bash scripts/install-synapse-http-antispam.sh${RESET}"
    fi
    echo
    echo -e "  ${BOLD}Next steps${RESET}"
    echo -e "    1) Invite ${CYAN}${DRAUPNIR_BOT_MXID}${RESET} to your management room"
    echo -e "    2) Give the bot admin power level in managed rooms"
    echo -e "    3) Create a list with ${CYAN}!draupnir list create my-coc code-of-conduct-ban-list${RESET}"
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
  │   Draupnir Module Setup                            │
  │   Moderation bot for Matrix rooms and lists.       │
  │                                                    │
  └────────────────────────────────────────────────────┘
EOF
    echo -e "${RESET}"

    echo -e "${BOLD}  Step 1 of 5 — Load existing configuration${RESET}"
    load_env

    echo
    echo -e "${BOLD}  Step 2 of 5 — Draupnir configuration${RESET}"
    gather_config

    echo
    echo -e "${BOLD}  Step 3 of 5 — Generate config files${RESET}"
    generate_config

    echo
    echo -e "${BOLD}  Step 4 of 5 — Synapse antispam wiring${RESET}"
    configure_synapse_antispam

    echo
    echo -e "${BOLD}  Step 5 of 5 — Start services${RESET}"
    start_services

    print_summary
}

main "$@"
