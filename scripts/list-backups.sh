#!/usr/bin/env bash
# list-backups.sh — List available PostgreSQL backups
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
BACKUP_DIR="${PROJECT_DIR}/backups"
CONFIG_FILE="${BACKUP_DIR}/config.env"

source "${SCRIPT_DIR}/lib.sh"

load_backup_config() {
    if [[ -f "${CONFIG_FILE}" ]]; then
        set -o allexport
        # shellcheck disable=SC1090
        source "${CONFIG_FILE}"
        set +o allexport
    fi
    BACKUP_LOCAL_PATH="${BACKUP_LOCAL_PATH:-${BACKUP_DIR}}"
}

list_local_backups() {
    local count=0

    echo
    info "Local backups in ${BACKUP_LOCAL_PATH}:"
    echo

    while IFS= read -r backup_file; do
        ((count++)) || true

        local filename
        filename=$(basename "${backup_file}")

        local size
        size=$(du -h "${backup_file}" | cut -f1)

        local modified
        modified=$(date -r "${backup_file}" "+%Y-%m-%d %H:%M:%S")

        printf "  ${CYAN}%-3d${RESET}  ${BOLD}%s${RESET}  %s  %s\n" \
            "${count}" "${filename}" "${modified}" "${size}"
    done < <(find "${BACKUP_LOCAL_PATH}" -name "matrix_backup_*.sql.gz" -type f -print | sort -r)

    if [[ ${count} -eq 0 ]]; then
        warn "No local backups found."
    fi

    echo
    echo "  Total: ${count} backup(s)"
}

list_s3_backups() {
    if [[ "${BACKUP_S3_ENABLED:-false}" != "true" ]]; then
        return 0
    fi

    echo
    info "S3 backups in s3://${BACKUP_S3_BUCKET}/matrix/:"
    echo

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

    local count=0
    while IFS= read -r line; do
        ((count++)) || true

        local size
        size=$(echo "${line}" | awk '{print $1}')
        local filename
        filename=$(echo "${line}" | awk '{print $2}')
        filename=$(basename "${filename}")

        printf "  ${CYAN}%-3d${RESET}  ${BOLD}%s${RESET}  S3  %s\n" \
            "${count}" "${filename}" "${size}"
    done < <("${aws_cmd[@]}" s3 ls "s3://${BACKUP_S3_BUCKET}/matrix/" "${s3_opts[@]}" 2>/dev/null | grep -E "matrix_backup.*\.sql\.gz$" | awk '{print $3"  "$4}' | while read -r size line; do echo "${line} ${size}"; done | sort -r)

    if [[ ${count} -eq 0 ]]; then
        warn "No S3 backups found."
    fi

    echo
    echo "  Total: ${count} S3 backup(s)"
}

main() {
    load_backup_config

    echo
    echo -e "${BOLD}=== Matrix PostgreSQL Backups ===${RESET}"

    list_local_backups

    if [[ "${BACKUP_S3_ENABLED:-false}" == "true" ]]; then
        list_s3_backups
    fi

    echo
}

main "$@"
