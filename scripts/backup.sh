#!/usr/bin/env bash
# backup.sh — PostgreSQL backup for matrix-easy-deploy
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
    BACKUP_RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-7}"
    BACKUP_S3_ENDPOINT="${BACKUP_S3_ENDPOINT:-}"
}

check_dependencies() {
    local missing=()

    if ! command -v gzip &>/dev/null; then
        missing+=(gzip)
    fi

    if [[ "${BACKUP_S3_ENABLED:-false}" == "true" ]]; then
        if ! command -v aws &>/dev/null && ! command -v aws-cli &>/dev/null; then
            if ! docker run --rm --entrypoint aws amazon/aws-cli --version &>/dev/null 2>&1; then
                missing+=(aws)
            fi
        fi
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        die "Missing dependencies: ${missing[*]}. Please install them and try again."
    fi
}

get_postgres_container() {
    echo "matrix_postgres"
}

get_postgres_password() {
    if [[ -f "${PROJECT_DIR}/.env" ]]; then
        grep "^POSTGRES_PASSWORD=" "${PROJECT_DIR}/.env" | cut -d'=' -f2-
    else
        die ".env file not found. Cannot determine PostgreSQL password."
    fi
}

get_postgres_user() {
    echo "synapse"
}

ensure_backup_directory() {
    if [[ ! -d "${BACKUP_LOCAL_PATH}" ]]; then
        info "Creating backup directory: ${BACKUP_LOCAL_PATH}"
        mkdir -p "${BACKUP_LOCAL_PATH}"
    fi
}

generate_backup_filename() {
    local timestamp
    timestamp=$(date +"%Y-%m-%d_%H%M%S")
    echo "matrix_backup_${timestamp}.sql.gz"
}

perform_backup() {
    local backup_file="$1"
    local container
    container=$(get_postgres_container)
    local pg_user
    pg_user=$(get_postgres_user)
    local pg_pass
    pg_pass=$(get_postgres_password)

    info "Starting PostgreSQL backup…"

    if ! docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
        die "PostgreSQL container '${container}' is not running."
    fi

    info "Dumping all databases and roles…"
    if docker exec -e PGPASSWORD="${pg_pass}" "${container}" pg_dumpall -U "${pg_user}" 2>/dev/null | gzip > "${backup_file}"; then
        local size
        size=$(du -h "${backup_file}" | cut -f1)
        success "Backup created: ${backup_file} (${size})"
    else
        rm -f "${backup_file}"
        die "Backup failed."
    fi
}

upload_to_s3() {
    local backup_file="$1"

    if [[ "${BACKUP_S3_ENABLED:-false}" != "true" ]]; then
        return 0
    fi

    info "Uploading backup to S3…"

    local s3_path="s3://${BACKUP_S3_BUCKET}/matrix/$(basename "${backup_file}")"
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

    if "${aws_cmd[@]}" s3 cp "${backup_file}" "${s3_path}" "${s3_opts[@]}"; then
        success "Uploaded to S3: ${s3_path}"
    else
        warn "Failed to upload to S3. Local backup is still available."
    fi
}

cleanup_old_backups() {
    if [[ "${BACKUP_RETENTION_DAYS:-0}" -le 0 ]]; then
        return 0
    fi

    info "Cleaning up backups older than ${BACKUP_RETENTION_DAYS} days…"

    local count
    count=$(find "${BACKUP_LOCAL_PATH}" -name "matrix_backup_*.sql.gz" -type f -mtime "+${BACKUP_RETENTION_DAYS}" -print | wc -l)

    if [[ "${count}" -gt 0 ]]; then
        find "${BACKUP_LOCAL_PATH}" -name "matrix_backup_*.sql.gz" -type f -mtime "+${BACKUP_RETENTION_DAYS}" -delete
        success "Removed ${count} old backup(s)."
    else
        info "No old backups to remove."
    fi
}

main() {
    load_backup_config
    check_dependencies
    ensure_backup_directory

    local backup_filename
    backup_filename=$(generate_backup_filename)
    local backup_path="${BACKUP_LOCAL_PATH}/${backup_filename}"

    perform_backup "${backup_path}"
    upload_to_s3 "${backup_path}"
    cleanup_old_backups

    echo
    success "Backup completed successfully!"
    echo
    info "Local backup: ${backup_path}"
    if [[ "${BACKUP_S3_ENABLED:-false}" == "true" ]]; then
        info "S3 backup:   s3://${BACKUP_S3_BUCKET}/matrix/${backup_filename}"
    fi
}

main "$@"
