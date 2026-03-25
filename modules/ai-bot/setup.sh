#!/usr/bin/env bash
# =============================================================================
#  matrix-easy-deploy  —  modules/ai-bot/setup.sh
#  Sets up the Baibot AI bot as an appservice on the existing Synapse server.
#
#  Run via:  bash matrix-wizard.sh --module ai-bot
#
#  What this does:
#    1. Reads the existing .env to discover your homeserver details.
#    2. Asks for AI provider configuration (OpenAI, Ollama, LocalAI, etc.).
#    3. Asks for authentication method (password or access token).
#    4. Asks for admin user patterns.
#    5. Generates encryption keys and recovery passphrase.
#    6. Renders config.yml from template.
#    7. Optionally adds a Caddy reverse-proxy block for bot domain.
#    8. Starts the Baibot container.
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck source=../../scripts/lib.sh
source "${PROJECT_ROOT}/scripts/lib.sh"

IFS=' ' read -ra DOCKER_COMPOSE <<< "$(docker_compose_cmd)"

VARS_FILE=""
cleanup() { [[ -n "$VARS_FILE" ]] && rm -f "$VARS_FILE"; }
trap cleanup EXIT

DEPLOY_ENV="${PROJECT_ROOT}/.env"
MODULE_DIR="${SCRIPT_DIR}"
BAIBOT_DATA_DIR="${MODULE_DIR}/baibot"
HOMESERVER_YAML="${PROJECT_ROOT}/modules/core/synapse/homeserver.yaml"
CADDYFILE="${PROJECT_ROOT}/caddy/Caddyfile"

declare -A AI_PROVIDERS=(
    ["openai"]="OpenAI"
    ["ollama"]="Ollama"
    ["localai"]="LocalAI"
    ["groq"]="Groq"
    ["anthropic"]="Anthropic"
    ["openrouter"]="OpenRouter"
)

declare -A AI_DEFAULT_MODELS=(
    ["openai"]="gpt-4o"
    ["ollama"]="llama3.2"
    ["localai"]="gpt-4"
    ["groq"]="llama-3.3-70b-versatile"
    ["anthropic"]="claude-3-5-sonnet-20241022"
    ["openrouter"]="anthropic/claude-3.5-sonnet"
)

declare -A AI_BASE_URLS=(
    ["openai"]="https://api.openai.com/v1"
    ["ollama"]="http://localhost:11434/v1"
    ["localai"]="http://localhost:8080/v1"
    ["groq"]="https://api.groq.com/openai/v1"
    ["anthropic"]="https://api.anthropic.com/v1"
    ["openrouter"]="https://openrouter.ai/api/v1"
)

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

    export HOMESERVER_URL="https://${MATRIX_DOMAIN}"
    success "Loaded: MATRIX_DOMAIN=${MATRIX_DOMAIN}, SERVER_NAME=${SERVER_NAME}"
}

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
    warn   "SERVER_NAME mismatch detected!"
    echo   -e "  ${BOLD}.env has:${RESET}             ${RED}${SERVER_NAME}${RESET}"
    echo   -e "  ${BOLD}homeserver.yaml has:${RESET}  ${GREEN}${actual_server_name}${RESET}"
    echo
    echo   -e "  Using the homeserver.yaml value for this module setup."
    echo

    SERVER_NAME="$actual_server_name"
    export SERVER_NAME
}

gather_ai_provider() {
    echo
    echo -e "${BOLD}  AI Provider Configuration${RESET}"
    echo -e "  ─────────────────────────────────────────────────────"
    echo -e "  Choose your AI provider:\n"

    local i=1
    local providers=()
    for key in "${!AI_PROVIDERS[@]}"; do
        echo -e "  ${CYAN}${i})${RESET} ${AI_PROVIDERS[$key]}"
        providers+=("$key")
        ((i++))
    done
    echo

    local choice
    ask choice "Select AI provider" "1"
    choice="${choice:-1}"

    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#providers[@]} )); then
        AI_PROVIDER="${providers[$((choice - 1))]}"
    else
        AI_PROVIDER="openai"
    fi

    export AI_PROVIDER
    info "Selected provider: ${AI_PROVIDERS[$AI_PROVIDER]}"

    local default_model="${AI_DEFAULT_MODELS[$AI_PROVIDER]}"
    local default_base_url="${AI_BASE_URLS[$AI_PROVIDER]}"

    echo
    if [[ "$AI_PROVIDER" == "ollama" || "$AI_PROVIDER" == "localai" ]]; then
        ask AI_BASE_URL "Base URL for ${AI_PROVIDERS[$AI_PROVIDER]}" "$default_base_url"
        while [[ -z "$AI_BASE_URL" ]]; do
            warn "Base URL is required."
            ask AI_BASE_URL "Base URL" "$default_base_url"
        done
        export AI_BASE_URL
    fi

    ask AI_MODEL "Model to use" "$default_model"
    while [[ -z "$AI_MODEL" ]]; do
        warn "Model is required."
        ask AI_MODEL "Model to use" "$default_model"
    done
    export AI_MODEL

    if [[ "$AI_PROVIDER" != "ollama" && "$AI_PROVIDER" != "localai" ]]; then
        ask AI_API_KEY "API key for ${AI_PROVIDERS[$AI_PROVIDER]}" ""
        while [[ -z "$AI_API_KEY" ]]; do
            warn "API key is required."
            ask AI_API_KEY "API key" ""
        done
        export AI_API_KEY
    fi
}

gather_auth_method() {
    echo
    echo -e "${BOLD}  Authentication Configuration${RESET}"
    echo -e "  ─────────────────────────────────────────────────────"
    echo -e "  How should Baibot authenticate with your homeserver?\n"
    echo -e "  ${CYAN}1)${RESET} Bot password (traditional — simpler setup)"
    echo -e "  ${CYAN}2)${RESET} Access token (for OIDC/MAS-enabled homeservers)\n"

    local auth_choice
    ask auth_choice "Authentication method" "1"
    auth_choice="${auth_choice:-1}"

    if [[ "$auth_choice" == "2" ]]; then
        AUTH_METHOD="token"
        echo
        echo -e "  ${YELLOW}Access token setup:${RESET}"
        echo -e "  To generate a compatibility token, run on your server:"
        echo -e "  ${CYAN}mas-cli manage issue-compatibility-token baibot [device_id]${RESET}"
        echo
        ask BAIBOT_ACCESS_TOKEN "Access token" ""
        while [[ -z "$BAIBOT_ACCESS_TOKEN" ]]; do
            warn "Access token is required."
            ask BAIBOT_ACCESS_TOKEN "Access token" ""
        done
        export BAIBOT_ACCESS_TOKEN

        ask BAIBOT_DEVICE_ID "Device ID (optional, press Enter to skip)" ""
        export BAIBOT_DEVICE_ID
    else
        AUTH_METHOD="password"
        ask_secret BAIBOT_PASSWORD "Bot password"
        while [[ -z "$BAIBOT_PASSWORD" ]]; do
            warn "Password is required."
            ask_secret BAIBOT_PASSWORD "Bot password"
        done
        export BAIBOT_PASSWORD
    fi
}

gather_admin_users() {
    echo
    echo -e "${BOLD}  Admin Configuration${RESET}"
    echo -e "  ─────────────────────────────────────────────────────"
    echo -e "  Users listed here can administer Baibot (change models, etc.).\n"
    echo -e "  Format: @username:${SERVER_NAME} (space-separated for multiple)\n"

    local default_admin="@admin:${SERVER_NAME}"
    ask BAIBOT_ADMIN_PATTERNS "Admin user patterns" "$default_admin"
    while [[ -z "$BAIBOT_ADMIN_PATTERNS" ]]; do
        warn "At least one admin pattern is required."
        ask BAIBOT_ADMIN_PATTERNS "Admin user patterns" "$default_admin"
    done
    export BAIBOT_ADMIN_PATTERNS

    echo
    echo -e "${BOLD}  Optional: Baibot Domain${RESET}"
    echo -e "  ─────────────────────────────────────────────────────"
    echo -e "  If you want Baibot accessible via a public domain (optional),\n"
    echo -e "  enter it now. Otherwise, press Enter to skip.\n"

    local suggested_domain="baibot.$(extract_base_domain "$MATRIX_DOMAIN")"
    ask BAIBOT_DOMAIN "Baibot domain (optional)" ""

    if [[ -n "$BAIBOT_DOMAIN" ]]; then
        echo
        echo -e "  ${YELLOW}DNS check:${RESET} make sure this A record points to this server:"
        echo -e "    ${CYAN}${BAIBOT_DOMAIN}${RESET}  →  <this server's IP>"
        echo
        ask_yn _confirm "Does this look right?" "y"
        if [[ "$_confirm" != "y" ]]; then
            BAIBOT_DOMAIN=""
        fi
    fi

    export BAIBOT_DOMAIN
}

print_config_summary() {
    echo
    echo -e "${BOLD}  Configuration summary${RESET}"
    echo -e "  ─────────────────────────────────────────────────────"
    echo -e "  Homeserver     : ${CYAN}${MATRIX_DOMAIN}${RESET}"
    echo -e "  Server name    : ${CYAN}${SERVER_NAME}${RESET}"
    echo -e "  AI Provider    : ${CYAN}${AI_PROVIDERS[$AI_PROVIDER]}${RESET}"
    echo -e "  Model          : ${CYAN}${AI_MODEL}${RESET}"
    if [[ -n "${AI_BASE_URL:-}" ]]; then
        echo -e "  Base URL       : ${CYAN}${AI_BASE_URL}${RESET}"
    fi
    echo -e "  Auth method    : ${CYAN}$([ "$AUTH_METHOD" == "token" ] && echo "Access token" || echo "Password")${RESET}"
    echo -e "  Admin patterns : ${CYAN}${BAIBOT_ADMIN_PATTERNS}${RESET}"
    if [[ -n "${BAIBOT_DOMAIN:-}" ]]; then
        echo -e "  Bot domain     : ${CYAN}${BAIBOT_DOMAIN}${RESET}"
    else
        echo -e "  Bot domain     : ${YELLOW}(none — internal only)${RESET}"
    fi
    echo

    ask_yn _confirm "Does this look right? Proceed?" "y"
    if [[ "$_confirm" != "y" ]]; then
        warn "Restarting configuration…"
        echo
        gather_ai_provider
        gather_auth_method
        gather_admin_users
        print_config_summary
    fi
}

generate_secrets() {
    info "Generating encryption keys…"

    SESSION_ENCRYPTION_KEY="$(openssl rand -hex 32)"
    CONFIG_ENCRYPTION_KEY="$(openssl rand -hex 32)"

    info "Generating recovery passphrase…"
    RECOVERY_PASSPHRASE="$(openssl rand -base64 32)"

    export SESSION_ENCRYPTION_KEY CONFIG_ENCRYPTION_KEY RECOVERY_PASSPHRASE
    success "Secrets generated."
}

build_config_blocks() {
    if [[ "$AUTH_METHOD" == "token" ]]; then
        if [[ -n "${BAIBOT_DEVICE_ID:-}" ]]; then
            USER_AUTH_BLOCK="  access_token: ${BAIBOT_ACCESS_TOKEN}
  device_id: ${BAIBOT_DEVICE_ID}"
        else
            USER_AUTH_BLOCK="  access_token: ${BAIBOT_ACCESS_TOKEN}"
        fi
    else
        USER_AUTH_BLOCK="  password: ${BAIBOT_PASSWORD}"
    fi
    export USER_AUTH_BLOCK

    local admin_patterns_formatted=""
    for pattern in $BAIBOT_ADMIN_PATTERNS; do
        admin_patterns_formatted+="    - \"${pattern}\"
"
    done
    export ADMIN_PATTERNS="${admin_patterns_formatted}"

    case "$AI_PROVIDER" in
        openai)
            AGENT_CONFIG="agents:
  static_definitions:
    - id: ${AI_PROVIDER}
      provider: openai
      config:
        base_url: https://api.openai.com/v1
        api_key: ${AI_API_KEY}
        text_generation:
          model_id: ${AI_MODEL}
          prompt: \"You are a helpful AI assistant called baibot. Be concise and friendly.\"
          temperature: 1.0
          max_response_tokens: 16384
          max_context_tokens: 128000
          tools:
            web_search: false
            code_interpreter: false"
            ;;
        ollama)
            AGENT_CONFIG="agents:
  static_definitions:
    - id: ${AI_PROVIDER}
      provider: ollama
      config:
        base_url: \"${AI_BASE_URL}\"
        api_key: null
        text_generation:
          model_id: \"${AI_MODEL}\"
          prompt: \"You are a helpful AI assistant called baibot. Be concise and friendly.\"
          temperature: 1.0
          max_response_tokens: 4096
          max_context_tokens: 128000"
            ;;
        localai)
            AGENT_CONFIG="agents:
  static_definitions:
    - id: ${AI_PROVIDER}
      provider: localai
      config:
        base_url: \"${AI_BASE_URL}\"
        api_key: null
        text_generation:
          model_id: \"${AI_MODEL}\"
          prompt: \"You are a helpful AI assistant called baibot. Be concise and friendly.\"
          temperature: 1.0
          max_response_tokens: 4096
          max_context_tokens: 128000"
            ;;
        groq)
            AGENT_CONFIG="agents:
  static_definitions:
    - id: ${AI_PROVIDER}
      provider: openai
      config:
        base_url: https://api.groq.com/openai/v1
        api_key: ${AI_API_KEY}
        text_generation:
          model_id: ${AI_MODEL}
          prompt: \"You are a helpful AI assistant called baibot. Be concise and friendly.\"
          temperature: 1.0
          max_response_tokens: 8192
          max_context_tokens: 128000"
            ;;
        anthropic)
            AGENT_CONFIG="agents:
  static_definitions:
    - id: ${AI_PROVIDER}
      provider: anthropic
      config:
        api_key: ${AI_API_KEY}
        text_generation:
          model_id: ${AI_MODEL}
          prompt: \"You are a helpful AI assistant called baibot. Be concise and friendly.\"
          temperature: 1.0
          max_response_tokens: 8192
          max_context_tokens: 200000"
            ;;
        openrouter)
            AGENT_CONFIG="agents:
  static_definitions:
    - id: ${AI_PROVIDER}
      provider: openai
      config:
        base_url: https://openrouter.ai/api/v1
        api_key: ${AI_API_KEY}
        text_generation:
          model_id: ${AI_MODEL}
          prompt: \"You are a helpful AI assistant called baibot. Be concise and friendly.\"
          temperature: 1.0
          max_response_tokens: 16384
          max_context_tokens: 128000"
            ;;
    esac
    export AGENT_CONFIG

    export HANDLER_TEXT_GENERATION="{\"type\": \"static\", \"agent_id\": \"${AI_PROVIDER}\"}"
}

save_env() {
    if ! grep -q "^BAIBOT_DOMAIN=" "$DEPLOY_ENV" 2>/dev/null; then
        info "Appending Baibot variables to .env…"
        cat >> "$DEPLOY_ENV" <<EOF

# Baibot module — added by modules/ai-bot/setup.sh
BAIBOT_DOMAIN=${BAIBOT_DOMAIN:-}
BAIBOT_AI_PROVIDER=${AI_PROVIDER}
BAIBOT_AI_MODEL=${AI_MODEL}
BAIBOT_AI_BASE_URL=${AI_BASE_URL:-}
BAIBOT_AUTH_METHOD=${AUTH_METHOD}
EOF
        success ".env updated."
    else
        info "Baibot variables already present in .env — skipping."
    fi
}

render_config() {
    mkdir -p "$BAIBOT_DATA_DIR"

    VARS_FILE="$(mktemp)"

    cat > "$VARS_FILE" <<EOF
SERVER_NAME=${SERVER_NAME}
HOMESERVER_URL=${HOMESERVER_URL}
USER_AUTH_BLOCK=${USER_AUTH_BLOCK}
RECOVERY_PASSPHRASE=${RECOVERY_PASSPHRASE}
ADMIN_PATTERNS=${ADMIN_PATTERNS}
SESSION_ENCRYPTION_KEY=${SESSION_ENCRYPTION_KEY}
CONFIG_ENCRYPTION_KEY=${CONFIG_ENCRYPTION_KEY}
AGENT_CONFIG=${AGENT_CONFIG}
HANDLER_TEXT_GENERATION=${HANDLER_TEXT_GENERATION}
EOF

    info "Rendering baibot/config.yml…"
    render_template \
        "${MODULE_DIR}/baibot/config.yml.template" \
        "${BAIBOT_DATA_DIR}/config.yml" \
        "$VARS_FILE"

    local numeric_uid
    numeric_uid=$(id -u)
    sed -i "s|user: \"1000:1000\"|user: \"${numeric_uid}:${numeric_uid}\"|" \
        "${MODULE_DIR}/docker-compose.yml"

    success "baibot/config.yml written."
}

update_caddy() {
    if [[ -z "${BAIBOT_DOMAIN:-}" ]]; then
        info "No bot domain configured — skipping Caddy update."
        return
    fi

    if grep -qF "$BAIBOT_DOMAIN" "$CADDYFILE"; then
        info "Caddy block for ${BAIBOT_DOMAIN} already exists — skipping."
        return
    fi

    info "Appending Baibot Caddy block to ${CADDYFILE}…"
    cat >> "$CADDYFILE" <<EOF

# Baibot AI bot — public ingress
${BAIBOT_DOMAIN} {
    reverse_proxy matrix-baibot:8080

    header {
        X-Content-Type-Options nosniff
        X-Frame-Options SAMEORIGIN
        Referrer-Policy strict-origin-when-cross-origin
        -Server
    }

    log
}
EOF
    success "Caddy block added."

    info "Reloading Caddy…"
    if docker ps --format '{{.Names}}' | grep -q '^caddy$'; then
        docker exec caddy caddy reload --config /etc/caddy/Caddyfile 2>&1 | sed 's/^/    /'
        success "Caddy reloaded."
    else
        warn "Caddy container is not running. The new site block will be active on next start."
    fi
}

start_services() {
    echo
    info "Starting Baibot…"
    (cd "$MODULE_DIR" && "${DOCKER_COMPOSE[@]}" up -d --pull always)
    success "Baibot started."

    echo
    info "Waiting for Baibot to be ready…"
    sleep 5

    if docker ps --format '{{.Names}}' | grep -q '^matrix-baibot$'; then
        info "Baibot container is running."
        docker logs matrix-baibot 2>&1 | tail -20 | sed 's/^/    /'
    fi
}

print_summary() {
    echo
    echo -e "${GREEN}${BOLD}"
    cat << 'EOF'
  ┌─────────────────────────────────────────────────────┐
  │                                                     │
  │         Baibot AI Bot module installed!             │
  │                                                     │
  └─────────────────────────────────────────────────────┘
EOF
    echo -e "${RESET}"
    echo -e "  Baibot is live. Here's a quick reference:\n"

    if [[ -n "${BAIBOT_DOMAIN:-}" ]]; then
        echo -e "  ${BOLD}Bot domain${RESET}       https://${BAIBOT_DOMAIN}/"
    fi
    echo -e "  ${BOLD}Bot username${RESET}      @baibot:${SERVER_NAME}"
    echo -e "  ${BOLD}AI Provider${RESET}       ${AI_PROVIDERS[$AI_PROVIDER]}"
    echo -e "  ${BOLD}Model${RESET}             ${AI_MODEL}"
    echo
    echo -e "  ${BOLD}Usage:${RESET}"
    echo -e "    Invite @baibot:${SERVER_NAME} to a room"
    echo -e "    Send ${CYAN}!bai help${RESET} to see available commands"
    echo
    echo -e "  ${BOLD}Useful commands${RESET}"
    echo -e "    Logs:     ${CYAN}docker logs -f matrix-baibot${RESET}"
    echo -e "    Restart:  ${CYAN}docker restart matrix-baibot${RESET}"
    echo -e "    Stop:     ${CYAN}cd modules/ai-bot && docker compose down${RESET}"
    echo
    echo -e "  Config file: ${CYAN}modules/ai-bot/baibot/config.yml${RESET}"
    echo
}

main() {
    echo
    echo -e "${BOLD}${CYAN}"
    cat << 'EOF'
  ┌────────────────────────────────────────────────────┐
  │                                                    │
  │   Baibot AI Bot Module Setup                       │
  │   An AI-powered bot for your Matrix server.        │
  │                                                    │
  └────────────────────────────────────────────────────┘
EOF
    echo -e "${RESET}"

    echo -e "${BOLD}  Step 1 of 6 — Load existing configuration${RESET}"
    load_env

    echo
    echo -e "${BOLD}  Step 2 of 6 — Verify server_name consistency${RESET}"
    verify_server_name

    echo
    echo -e "${BOLD}  Step 3 of 6 — AI provider configuration${RESET}"
    gather_ai_provider

    echo
    echo -e "${BOLD}  Step 4 of 6 — Authentication configuration${RESET}"
    gather_auth_method

    echo
    echo -e "${BOLD}  Step 5 of 6 — Admin configuration${RESET}"
    gather_admin_users

    echo
    echo -e "${BOLD}  Step 6 of 6 — Review and generate configuration${RESET}"
    print_config_summary

    generate_secrets
    build_config_blocks
    save_env
    render_config
    update_caddy
    start_services

    print_summary
}

main "$@"
