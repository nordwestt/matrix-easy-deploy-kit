#!/usr/bin/env bash
# restore.sh — Interactive PostgreSQL restore for matrix-easy-deploy
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
BACKUP_DIR="${PROJECT_DIR}/backups"
CONFIG_FILE="${BACKUP_DIR}/config.env"

source "${SCRIPT_DIR}/lib.sh"

declare -a LOCAL_BACKUPS=()
declare -a S3_BACKUP_PATHS=()

load_backup_config() {
    if [[ -f "${CONFIG_FILE}" ]]; then
        set -o allexport
        # shellcheck disable=SC1090
        source "${CONFIG_FILE}"
        set +o allexport
    fi
    BACKUP_LOCAL_PATH="${BACKUP_LOCAL_PATH:-${BACKUP_DIR}}"
}

collect_local_backups() {
    LOCAL_BACKUPS=()
    while IFS= read -r backup_file; do
        LOCAL_BACKUPS+=("${backup_file}")
    done < <(find "${BACKUP_LOCAL_PATH}" -name "matrix_backup_*.sql.gz" -type f -print | sort -r)
}

collect_s3_backups() {
    if [[ "${BACKUP_S3_ENABLED:-false}" != "true" ]]; then
        return 0
    fi

    S3_BACKUP_PATHS=()

    local aws_cmd=()
    if command -v aws &>/dev/null; then
        aws_cmd=(aws)
    elif command -v aws-cli &>/dev/null; then
        aws_cmd=(aws-cli)
    else
        aws_cmd=(docker run --rm --entrypoint aws -e AWS_ACCESS_KEY_ID="${BACKUP_S3_ACCESS_KEY}" -e AWS_SECRET_ACCESS_KEY="${BACKUP_S3_SECRET_KEY}" amazon/aws-cli)
    fi

    local s3_opts=(--only-show-errors)
    if [[ -n "${BACKUP_S3_ENDPOINT:-}" ]]; then
        s3_opts+=(--endpoint-url "${BACKUP_S3_ENDPOINT}")
    fi
    if [[ -n "${BACKUP_S3_REGION:-}" ]]; then
        s3_opts+=(--region "${BACKUP_S3_REGION}")
    fi

    while IFS= read -r line; do
        local s3_path
        s3_path=$(echo "${line}" | awk '{print $4}')
        if [[ -n "${s3_path}" ]]; then
            S3_BACKUP_PATHS+=("${s3_path}")
        fi
    done < <("${aws_cmd[@]}" s3 ls "s3://${BACKUP_S3_BUCKET}/matrix/" "${s3_opts[@]}" 2>/dev/null | grep -E "matrix_backup.*\.sql\.gz$")
}

display_backup_menu() {
    local count=0
    local total_count=0

    echo
    echo -e "${BOLD}=== Select Backup to Restore ===${RESET}"
    echo
    echo "  ${BOLD}Local Backups:${RESET}"
    echo

    if [[ ${#LOCAL_BACKUPS[@]} -eq 0 ]]; then
        echo "    No local backups available."
    else
        for backup_file in "${LOCAL_BACKUPS[@]}"; do
            ((count++)) || true
            local filename
            filename=$(basename "${backup_file}")
            local size
            size=$(du -h "${backup_file}" | cut -f1)
            local modified
            modified=$(date -r "${backup_file}" "+%Y-%m-%d %H:%M:%S")
            printf "  ${CYAN}%3d${RESET}  ${BOLD}%-45s${RESET}  %s  %s\n" \
                "${count}" "${filename}" "${modified}" "${size}"
        done
    fi

    if [[ "${BACKUP_S3_ENABLED:-false}" == "true" && ${#S3_BACKUP_PATHS[@]} -gt 0 ]]; then
        echo
        echo "  ${BOLD}S3 Backups:${RESET}"
        echo

        for s3_path in "${S3_BACKUP_PATHS[@]}"; do
            ((count++)) || true
            local filename
            filename=$(basename "${s3_path}")
            printf "  ${CYAN}%3d${RESET}  ${BOLD}%-45s${RESET}  %s\n" \
                "${count}" "${filename}" "S3"
        done
    fi

    echo
    echo "  ${CYAN}0${RESET}   Cancel"
    echo
}

select_backup() {
    display_backup_menu

    local selection
    local max_selection=$(( ${#LOCAL_BACKUPS[@]} + ${#S3_BACKUP_PATHS[@]} ))

    while true; do
        echo -ne "${BOLD}  Enter selection${RESET} ${CYAN}[0-${max_selection}]${RESET}: "
        read -r selection

        if [[ "${selection}" == "0" ]]; then
            echo
            info "Restore cancelled."
            exit 0
        fi

        if [[ -n "${selection}" && "${selection}" =~ ^[0-9]+$ ]] && [[ "${selection}" -ge 1 && "${selection}" -le "${max_selection}" ]]; then
            break
        fi

        warn "Invalid selection. Please enter a number between 0 and ${max_selection}."
    done

    echo
    info "Selected: ${selection}"

    if [[ "${selection}" -le ${#LOCAL_BACKUPS[@]} ]]; then
        SELECTED_BACKUP="${LOCAL_BACKUPS[$((selection - 1))]}"
        BACKUP_SOURCE="local"
    else
        local s3_index=$((selection - ${#LOCAL_BACKUPS[@]} - 1))
        SELECTED_BACKUP="${S3_BACKUP_PATHS[$s3_index]}"
        BACKUP_SOURCE="s3"
    fi
}

download_s3_backup() {
    local s3_path="$1"
    local local_path="$2"

    info "Downloading backup from S3…"

    local aws_cmd=()
    if command -v aws &>/dev/null; then
        aws_cmd=(aws)
    elif command -v aws-cli &>/dev/null; then
        aws_cmd=(aws-cli)
    else
        aws_cmd=(docker run --rm --entrypoint aws -e AWS_ACCESS_KEY_ID="${BACKUP_S3_ACCESS_KEY}" -e AWS_SECRET_ACCESS_KEY="${BACKUP_S3_SECRET_KEY}" amazon/aws-cli)
    fi

    local s3_opts=(--only-show-errors)
    if [[ -n "${BACKUP_S3_ENDPOINT:-}" ]]; then
        s3_opts+=(--endpoint-url "${BACKUP_S3_ENDPOINT}")
    fi
    if [[ -n "${BACKUP_S3_REGION:-}" ]]; then
        s3_opts+=(--region "${BACKUP_S3_REGION}")
    fi

    if ! "${aws_cmd[@]}" s3 cp "${s3_path}" "${local_path}" "${s3_opts[@]}"; then
        die "Failed to download backup from S3."
    fi

    success "Backup downloaded."
}

stop_services() {
    info "Stopping Matrix services…"

    if [[ -x "${PROJECT_DIR}/stop.sh" ]]; then
        cd "${PROJECT_DIR}" && bash stop.sh
    else
        IFS=' ' read -ra DOCKER_COMPOSE <<< "$(docker_compose_cmd)"

        if [[ -f "${PROJECT_DIR}/modules/whatsapp-bridge/whatsapp/config.yaml" ]]; then
            (cd "${PROJECT_DIR}/modules/whatsapp-bridge" && "${DOCKER_COMPOSE[@]}" down)
        fi

        if [[ -f "${PROJECT_DIR}/modules/slack-bridge/slack/config.yaml" ]]; then
            (cd "${PROJECT_DIR}/modules/slack-bridge" && "${DOCKER_COMPOSE[@]}" down)
        fi

        (cd "${PROJECT_DIR}/modules/calls" && "${DOCKER_COMPOSE[@]}" down)
        (cd "${PROJECT_DIR}/modules/core" && "${DOCKER_COMPOSE[@]}" down --remove-orphans)
    fi

    sleep 2
}

restore_backup() {
    local backup_file="$1"

    local container
    container="matrix_postgres"
    local pg_user
    pg_user="synapse"
    local pg_pass
    pg_pass=$(grep "^POSTGRES_PASSWORD=" "${PROJECT_DIR}/.env" | cut -d'=' -f2-)

    info "Restoring PostgreSQL backup…"

    if ! docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
        warn "PostgreSQL container is not running. Starting it temporarily…"
        IFS=' ' read -ra DOCKER_COMPOSE <<< "$(docker_compose_cmd)"
        (cd "${PROJECT_DIR}/modules/core" && "${DOCKER_COMPOSE[@]}" up -d postgres)

        local max_wait=30
        local waited=0
        until docker exec "${container}" pg_isready -U "${pg_user}" &>/dev/null; do
            sleep 1
            ((waited++)) || true
            if [[ ${waited} -ge ${max_wait} ]]; then
                die "PostgreSQL did not become ready in time."
            fi
        done
    fi

    if ! gunzip -c "${backup_file}" | docker exec -e PGPASSWORD="${pg_pass}" "${container}" psql -U "${pg_user}" -d postgres; then
        die "Restore failed. Check the output above for errors."
    fi

    success "Database restored successfully."
}

start_services() {
    info "Starting Matrix services…"

    if [[ -x "${PROJECT_DIR}/start.sh" ]]; then
        cd "${PROJECT_DIR}" && bash start.sh
    else
        IFS=' ' read -ra DOCKER_COMPOSE <<< "$(docker_compose_cmd)"

        (cd "${PROJECT_DIR}/modules/core" && "${DOCKER_COMPOSE[@]}" up -d)
        (cd "${PROJECT_DIR}/modules/calls" && "${DOCKER_COMPOSE[@]}" up -d)

        if [[ -f "${PROJECT_DIR}/modules/whatsapp-bridge/whatsapp/config.yaml" ]]; then
            (cd "${PROJECT_DIR}/modules/whatsapp-bridge" && "${DOCKER_COMPOSE[@]}" up -d)
        fi

        if [[ -f "${PROJECT_DIR}/modules/slack-bridge/slack/config.yaml" ]]; then
            (cd "${PROJECT_DIR}/modules/slack-bridge" && "${DOCKER_COMPOSE[@]}" up -d)
        fi
    fi

    success "Services restarted."
}

main() {
    load_backup_config

    if [[ ! -d "${BACKUP_LOCAL_PATH}" ]] && [[ "${BACKUP_S3_ENABLED:-false}" != "true" ]]; then
        die "No backup directory found and S3 is not configured. Run backup.sh first."
    fi

    collect_local_backups
    collect_s3_backups

    if [[ ${#LOCAL_BACKUPS[@]} -eq 0 && "${BACKUP_S3_ENABLED:-false}" != "true" ]]; then
        die "No backups found. Run backup.sh first."
    fi

    if [[ ${#LOCAL_BACKUPS[@]} -eq 0 && ${#S3_BACKUP_PATHS[@]} -eq 0 ]]; then
        die "No backups found. Run backup.sh first."
    fi

    SELECTED_BACKUP=""
    BACKUP_SOURCE=""

    select_backup

    echo
    warn "WARNING: This will replace ALL current database data with the backup!"
    echo
    ask_yn confirm "Are you sure you want to restore this backup?"
    if [[ "${confirm}" != "y" ]]; then
        info "Restore cancelled."
        exit 0
    fi

    local temp_backup=""
    if [[ "${BACKUP_SOURCE}" == "s3" ]]; then
        temp_backup="/tmp/$(basename "${SELECTED_BACKUP}")"
        download_s3_backup "${SELECTED_BACKUP}" "${temp_backup}"
        SELECTED_BACKUP="${temp_backup}"
    fi

    stop_services
    restore_backup "${SELECTED_BACKUP}"

    if [[ -n "${temp_backup}" ]]; then
        rm -f "${temp_backup}"
    fi

    start_services

    echo
    success "Restore completed successfully!"
    echo
    info "Your Matrix server has been restored to the selected backup."
    echo
}

main "$@"
