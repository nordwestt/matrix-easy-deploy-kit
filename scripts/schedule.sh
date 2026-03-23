#!/usr/bin/env bash
# schedule.sh — Setup daily cron job for PostgreSQL backups
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
BACKUP_DIR="${PROJECT_DIR}/backups"
CONFIG_FILE="${BACKUP_DIR}/config.env"
CRON_FILE="/etc/cron.d/matrix-backup"
CRON_USER="${USER:-root}"
BACKUP_TIME="${BACKUP_TIME:-02:00}"

source "${SCRIPT_DIR}/lib.sh"

load_backup_config() {
    if [[ -f "${CONFIG_FILE}" ]]; then
        set -o allexport
        # shellcheck disable=SC1090
        source "${CONFIG_FILE}"
        set +o allexport
    fi
}

parse_time() {
    local time_str="$1"
    local hour minute

    if [[ "${time_str}" =~ ^([0-9]{1,2}):([0-9]{2})$ ]]; then
        hour="${BASH_REMATCH[1]}"
        minute="${BASH_REMATCH[2]}"
    else
        die "Invalid time format. Use HH:MM (e.g., 02:00)"
    fi

    if [[ "${hour}" -gt 23 ]] || [[ "${minute}" -gt 59 ]]; then
        die "Invalid time. Hour must be 0-23, minute must be 0-59."
    fi

    echo "${minute} ${hour} * * *"
}

install_cron() {
    local cron_schedule="$1"
    local backup_cmd="cd ${PROJECT_DIR} && ${SCRIPT_DIR}/backup.sh >> ${BACKUP_DIR}/backup.log 2>&1"

    info "Installing cron job…"

    if [[ -f "${CRON_FILE}" ]]; then
        warn "Cron file already exists. Removing old configuration."
        rm -f "${CRON_FILE}"
    fi

    if ! command -v sudo &>/dev/null; then
        die "sudo is required to install the cron job. Please install sudo or run as root."
    fi

    echo "${cron_schedule} ${CRON_USER} ${backup_cmd}" | sudo tee "${CRON_FILE}" > /dev/null
    sudo chmod 0644 "${CRON_FILE}"

    success "Cron job installed."
    echo
    info "Backup schedule: daily at ${BACKUP_TIME}"
    info "Log file: ${BACKUP_DIR}/backup.log"
}

remove_cron() {
    info "Removing backup cron job…"

    if [[ -f "${CRON_FILE}" ]]; then
        sudo rm -f "${CRON_FILE}"
        success "Cron job removed."
    else
        info "No cron job found. Nothing to remove."
    fi
}

show_status() {
    echo
    echo -e "${BOLD}=== Backup Schedule Status ===${RESET}"
    echo

    if [[ -f "${CRON_FILE}" ]]; then
        success "Cron job is installed:"
        echo
        cat "${CRON_FILE}" | sed 's/^/  /'
    else
        warn "No cron job installed."
    fi

    echo

    if [[ -f "${BACKUP_DIR}/backup.log" ]]; then
        info "Last backup log entry:"
        tail -3 "${BACKUP_DIR}/backup.log" | sed 's/^/  /'
    fi

    echo
}

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Setup automatic daily backups for PostgreSQL.

Options:
  --time HH:MM    Set backup time (default: 02:00)
  --remove         Remove the cron job
  --status         Show current schedule status
  -h, --help       Show this help message

Examples:
  $(basename "$0")                  Install daily backup at 02:00
  $(basename "$0") --time 03:30     Install daily backup at 03:30
  $(basename "$0") --remove         Remove the scheduled backup
  $(basename "$0") --status         Show current schedule

EOF
}

main() {
    local action="install"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --time)
                BACKUP_TIME="$2"
                shift 2
                ;;
            --remove)
                action="remove"
                shift
                ;;
            --status)
                action="status"
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                error "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done

    case "${action}" in
        install)
            load_backup_config

            if [[ ! -f "${CONFIG_FILE}" ]]; then
                warn "Backup config not found. Please run the wizard to set up backups first."
                info "Or create ${CONFIG_FILE} manually."
                exit 1
            fi

            local cron_schedule
            cron_schedule=$(parse_time "${BACKUP_TIME}")

            install_cron "${cron_schedule}"
            ;;
        remove)
            remove_cron
            ;;
        status)
            load_backup_config
            show_status
            ;;
    esac
}

main "$@"
