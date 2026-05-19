#!/usr/bin/env bash
# =============================================================================
# ssb.sh — Simple Swarm Backup
#
# Backs up local Docker container volumes and databases on each Swarm node.
# Designed to run from cron on each node independently; no central scheduler.
#
# Usage: ssb.sh [--config FILE] [--dry-run] [--help]
# =============================================================================

set -uo pipefail

BACKUP_BASE=""
RETENTION_DAYS=""
EXISTING_BACKUP_ACTION=""
HEALTHCHECK_URL=""
DOCKER_SRC=""
DOCKER_EXCLUDE_DIRS=()
BACKUP_GLUSTER=""
GLUSTER_DEST_NAME=""
GLUSTER_SRC=""
GLUSTER_EXCLUDE_DIRS=()

SCRIPT_PATH="${BASH_SOURCE[0]}"
SCRIPT_DIR=$(cd -- "$(dirname -- "${SCRIPT_PATH}")" && pwd)
readonly SCRIPT_DIR

CONFIG_FILE="./ssb.json"
CONFIG_FILE_FROM_ARG="false"

DATE=$(date +%Y-%m-%d)
readonly DATE

SHORT_HOSTNAME=$(hostname -s)
readonly SHORT_HOSTNAME

FULL_HOSTNAME=$(hostname)
readonly FULL_HOSTNAME

HOST_BACKUP_DIR=""
LOCK_FILE=""
LOG_FILE=""
DOCKER_BACKUP_DIR=""
DB_BACKUP_DIR=""
GLUSTER_BACKUP_DIR=""

DRY_RUN="false"
ERRORS=0

# =============================================================================
# LOGGING
# =============================================================================

_log() {
    local level="$1"; shift
    local msg="$*"
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    local line="[${ts}] [${level}] ${msg}"
    if [[ "${DRY_RUN}" == "true" ]]; then
        echo "${line}"
    else
        echo "${line}" | tee -a "${LOG_FILE}"
    fi
}

log_info()  { _log "INFO " "$@"; }
log_warn()  { _log "WARN " "$@"; }
log_error() { _log "ERROR" "$@"; ERRORS=$((ERRORS + 1)); }

# =============================================================================
# ARGUMENT PARSING
# =============================================================================

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Simple Swarm Backup — backs up local Docker volumes and databases on this node.

Options:
  --config FILE  Load JSON config FILE (default: ./ssb.json)
  --dry-run      Show what would be done without writing any files
  --help         Show this help message

Exit codes:
  0   All backup tasks completed successfully
  1   One or more backup tasks failed
  2   Invalid arguments
EOF
    exit 0
}

parse_args() {
    while [[ "$#" -gt 0 ]]; do
        case "$1" in
            --dry-run|-n)
                DRY_RUN="true"
                shift
                ;;
            --config)
                if [[ -z "${2:-}" ]]; then
                    echo "Missing value for --config" >&2
                    echo "Run '$(basename "$0") --help' for usage." >&2
                    exit 2
                fi
                # Support absolute or relative paths (relative to current directory)
                CONFIG_FILE="$2"
                CONFIG_FILE_FROM_ARG="true"
                shift 2
                ;;
            --config=*)
                local cfg_name
                cfg_name="${1#*=}"
                if [[ -z "${cfg_name}" ]]; then
                    echo "Missing value for --config" >&2
                    exit 2
                fi
                # Support absolute or relative paths (relative to current directory)
                CONFIG_FILE="${cfg_name}"
                CONFIG_FILE_FROM_ARG="true"
                shift
                ;;
            --help|-h)
                usage
                ;;
            *)
                echo "Unknown argument: $1" >&2
                echo "Run '$(basename "$0") --help' for usage." >&2
                exit 2
                ;;
        esac
    done

}

load_config() {
    if [[ ! -f "${CONFIG_FILE}" ]]; then
        echo "ERROR: Config file not found: ${CONFIG_FILE}" >&2
        exit 2
    fi

    if ! command -v jq &>/dev/null; then
        echo "ERROR: jq is required to parse JSON config files." >&2
        exit 2
    fi

    if ! jq -e . "${CONFIG_FILE}" >/dev/null 2>&1; then
        echo "ERROR: Invalid JSON in config file: ${CONFIG_FILE}" >&2
        exit 2
    fi

    local server_cfg
    server_cfg=$(jq -c \
        --arg short "${SHORT_HOSTNAME}" \
        --arg full "${FULL_HOSTNAME}" \
        '(.default // {}) + ((.servers // {})[$short] // (.servers // {})[$full] // {})' \
        "${CONFIG_FILE}")

    local value

    value=$(jq -r 'if has("backup_base") then .backup_base else empty end' <<< "${server_cfg}")
    [[ -n "${value}" ]] && BACKUP_BASE="${value}"

    value=$(jq -r 'if has("retention_days") then .retention_days|tostring else empty end' <<< "${server_cfg}")
    [[ -n "${value}" ]] && RETENTION_DAYS="${value}"

    value=$(jq -r 'if has("existing_backup_action") then .existing_backup_action else empty end' <<< "${server_cfg}")
    [[ -n "${value}" ]] && EXISTING_BACKUP_ACTION="${value}"

    value=$(jq -r 'if has("healthcheck_url") then .healthcheck_url else empty end' <<< "${server_cfg}")
    [[ -n "${value}" ]] && HEALTHCHECK_URL="${value}"

    value=$(jq -r 'if has("docker_src") then .docker_src else empty end' <<< "${server_cfg}")
    [[ -n "${value}" ]] && DOCKER_SRC="${value}"

        mapfile -t DOCKER_EXCLUDE_DIRS < <(
                jq -r '(.docker_exclude_dirs // [])[] | tostring' "${CONFIG_FILE}"
        )

    value=$(jq -r 'if has("backup_gluster") then .backup_gluster|tostring else empty end' <<< "${server_cfg}")
    if [[ -n "${value}" ]]; then
        value="${value,,}"
        if [[ "${value}" == "true" || "${value}" == "false" ]]; then
            BACKUP_GLUSTER="${value}"
        else
            echo "ERROR: backup_gluster must be true or false in ${CONFIG_FILE}" >&2
            exit 2
        fi
    fi

    value=$(jq -r 'if has("gluster_dest_name") then .gluster_dest_name else empty end' <<< "${server_cfg}")
    [[ -n "${value}" ]] && GLUSTER_DEST_NAME="${value}"

    value=$(jq -r 'if has("gluster_src") then .gluster_src else empty end' <<< "${server_cfg}")
    [[ -n "${value}" ]] && GLUSTER_SRC="${value}"

    mapfile -t GLUSTER_EXCLUDE_DIRS < <(jq -r '(.gluster_exclude_dirs // [])[] | tostring' <<< "${server_cfg}")

    local missing=0
    local required_key
    for required_key in BACKUP_BASE RETENTION_DAYS EXISTING_BACKUP_ACTION DOCKER_SRC BACKUP_GLUSTER GLUSTER_DEST_NAME GLUSTER_SRC; do
        if [[ -z "${!required_key}" ]]; then
            echo "ERROR: Missing required config value: ${required_key} in ${CONFIG_FILE}" >&2
            missing=$((missing + 1))
        fi
    done
    if [[ "${missing}" -gt 0 ]]; then
        exit 2
    fi
}

set_runtime_paths() {
    HOST_BACKUP_DIR="${BACKUP_BASE}/${SHORT_HOSTNAME}/${DATE}"
    LOCK_FILE="${BACKUP_BASE}/${SHORT_HOSTNAME}/backup-${DATE}.lock"
    LOG_FILE="${HOST_BACKUP_DIR}/backup.log"
    DOCKER_BACKUP_DIR="${HOST_BACKUP_DIR}/docker"
    DB_BACKUP_DIR="${HOST_BACKUP_DIR}/databases"
    GLUSTER_BACKUP_DIR="${BACKUP_BASE}/${GLUSTER_DEST_NAME}/${DATE}"
}

# =============================================================================
# PREREQUISITES CHECK
# =============================================================================

check_prerequisites() {
    # Require Bash 4.0+ for lowercase expansion (${var,,}) and other features
    if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
        echo "ERROR: ssb.sh requires Bash 4.0 or later (running ${BASH_VERSION})." >&2
        exit 1
    fi

    local missing=0
    for cmd in docker rsync curl jq gzip; do
        if ! command -v "${cmd}" &>/dev/null; then
            log_warn "Command not found: ${cmd}"
            missing=$((missing + 1))
        fi
    done
    if [[ "${missing}" -gt 0 ]]; then
        log_warn "${missing} prerequisite(s) missing — some backup steps may be skipped."
    fi
}

# =============================================================================
# LOCK FILE
# =============================================================================

acquire_lock() {
    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "[DRY-RUN] Would create lock file: ${LOCK_FILE}"
        return 0
    fi

    local lock_dir
    lock_dir=$(dirname "${LOCK_FILE}")
    mkdir -p "${lock_dir}"

    # Atomic lock creation via noclobber
    if ( set -C; echo $$ > "${LOCK_FILE}" ) 2>/dev/null; then
        log_info "Lock acquired: ${LOCK_FILE}"
        return 0
    fi

    # Lock already exists — check if the owning PID is still alive
    local existing_pid
    existing_pid=$(cat "${LOCK_FILE}" 2>/dev/null || echo "")

    if [[ -n "${existing_pid}" ]] && kill -0 "${existing_pid}" 2>/dev/null; then
        echo "ERROR: Another backup is already running (PID ${existing_pid}). Exiting." >&2
        exit 1
    fi

    # Stale lock — reclaim it atomically to avoid a race condition between
    # two processes that both detect the stale lock at the same time
    log_warn "Stale lock file found (PID ${existing_pid} is not running). Removing and re-locking."
    rm -f "${LOCK_FILE}"
    if ! ( set -C; echo $$ > "${LOCK_FILE}" ) 2>/dev/null; then
        echo "ERROR: Another process acquired the lock during stale-lock recovery. Exiting." >&2
        exit 1
    fi
    log_info "Lock acquired: ${LOCK_FILE}"
}

release_lock() {
    if [[ "${DRY_RUN}" == "true" ]]; then
        return 0
    fi
    if [[ -f "${LOCK_FILE}" ]]; then
        rm -f "${LOCK_FILE}"
        log_info "Lock released: ${LOCK_FILE}"
    fi
}

# =============================================================================
# SETUP
# =============================================================================

setup_dirs() {
    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "[DRY-RUN] Would create: ${DOCKER_BACKUP_DIR}"
        return 0
    fi

    if [[ -d "${HOST_BACKUP_DIR}" ]] && [[ "${EXISTING_BACKUP_ACTION}" == "keep" ]]; then
        log_info "Backup for ${DATE} already exists and EXISTING_BACKUP_ACTION=keep — exiting."
        release_lock
        exit 0
    fi

    mkdir -p "${DOCKER_BACKUP_DIR}"
    log_info "Output directories ready: ${HOST_BACKUP_DIR}"
}

# =============================================================================
# CONTAINER DISCOVERY
# =============================================================================

# Return names of all locally running containers (Swarm services and standalone)
get_local_containers() {
    docker ps --format '{{.Names}}' 2>/dev/null || true
}

# Read a label value from a container
get_container_label() {
    local container="$1"
    local label="$2"
    docker inspect \
        --format "{{ index .Config.Labels \"${label}\" }}" \
        "${container}" 2>/dev/null || echo ""
}

# Read an environment variable from a running container by inspecting its config
get_container_env() {
    local container="$1"
    local var_name="$2"
    docker inspect \
        --format '{{range .Config.Env}}{{println .}}{{end}}' \
        "${container}" 2>/dev/null \
        | grep "^${var_name}=" \
        | head -1 \
        | cut -d'=' -f2-
}

# =============================================================================
# MYSQL / MARIADB BACKUP
#
# Credential discovery order (container env vars):
#   1. Label override:
#      - ssb.backup-db-username=<ENV_VAR_NAME>
#      - ssb.backup-db-password=<ENV_VAR_NAME>
#   2. MYSQL_ROOT_PASSWORD or MARIADB_ROOT_PASSWORD  → user root
#   3. MYSQL_PASSWORD or MARIADB_PASSWORD            → MYSQL_USER / MARIADB_USER
#
# Recommended production approach: store passwords in Docker Secrets or a
# dedicated ~/.my.cnf inside the container, mounted from a secret volume.
#
# Specific databases: set label  ssb.backup-db-names=db1,db2
# All databases (default):       omit the label (uses --all-databases)
# =============================================================================

backup_mysql() {
    local container="$1"
    local dest_dir="${DB_BACKUP_DIR}/${container}"
    local db_names_label
    db_names_label=$(get_container_label "${container}" "ssb.backup-db-names")
    local user_env_label
    user_env_label=$(get_container_label "${container}" "ssb.backup-db-username")
    local pass_env_label
    pass_env_label=$(get_container_label "${container}" "ssb.backup-db-password")

    log_info "MySQL/MariaDB backup — container: ${container}"

    # Resolve credentials from container environment
    local mysql_user="root"
    local mysql_pass=""

    if [[ -n "${user_env_label}" ]]; then
        mysql_user=$(get_container_env "${container}" "${user_env_label}")
        if [[ -z "${mysql_user}" ]]; then
            log_warn "  Label ssb.backup-db-username='${user_env_label}' is set but env var is missing/empty. Falling back to defaults."
            mysql_user="root"
        fi
    fi

    if [[ -n "${pass_env_label}" ]]; then
        mysql_pass=$(get_container_env "${container}" "${pass_env_label}")
        if [[ -z "${mysql_pass}" ]]; then
            log_warn "  Label ssb.backup-db-password='${pass_env_label}' is set but env var is missing/empty. Falling back to defaults."
        fi
    fi

    local env_var
    if [[ -z "${mysql_pass}" ]]; then
        for env_var in MYSQL_ROOT_PASSWORD MARIADB_ROOT_PASSWORD; do
            mysql_pass=$(get_container_env "${container}" "${env_var}")
            if [[ -n "${mysql_pass}" ]]; then
                [[ -z "${user_env_label}" ]] && mysql_user="root"
                break
            fi
        done
    fi

    if [[ -z "${mysql_pass}" ]]; then
        for env_var in MYSQL_PASSWORD MARIADB_PASSWORD; do
            mysql_pass=$(get_container_env "${container}" "${env_var}")
            if [[ -n "${mysql_pass}" ]]; then
                if [[ -z "${user_env_label}" ]]; then
                    local u
                    u=$(get_container_env "${container}" "MYSQL_USER")
                    [[ -z "${u}" ]] && u=$(get_container_env "${container}" "MARIADB_USER")
                    mysql_user="${u:-root}"
                fi
                break
            fi
        done
    fi

    if [[ -z "${mysql_pass}" ]]; then
        log_warn "  No MySQL/MariaDB password found in container env for '${container}'. Attempting passwordless dump."
    fi

    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "[DRY-RUN] Would mysqldump container=${container} user=${mysql_user} databases=${db_names_label:-ALL}"
        return 0
    fi

    mkdir -p "${dest_dir}"

    if [[ -n "${db_names_label}" ]]; then
        # Specific databases listed in the label
        IFS=',' read -ra databases <<< "${db_names_label}"
        local db
        for db in "${databases[@]}"; do
            db="${db//[[:space:]]/}"
            [[ -z "${db}" ]] && continue
            log_info "  Dumping database: ${db}"
            local tmp_file
            tmp_file=$(mktemp "/tmp/ssb-mysql-${container}-${db}-XXXXXX.sql")
            local zip_file="${dest_dir}/${db}.sql.gz"
            if ! docker exec \
                -e "MYSQL_PWD=${mysql_pass}" \
                "${container}" \
                mysqldump -u "${mysql_user}" --single-transaction --quick "${db}" \
                > "${tmp_file}"; then
                rm -f "${tmp_file}"
                log_error "  mysqldump failed for database '${db}' in container '${container}'"
            else
                if gzip -c "${tmp_file}" > "${zip_file}"; then
                    log_info "  Saved: ${zip_file} (gzipped)"
                else
                    log_error "  gzip failed for ${tmp_file}"
                fi
                rm -f "${tmp_file}"
            fi
        done
    else
        # Full cluster dump
        log_info "  Dumping all databases"
        local tmp_file
        tmp_file=$(mktemp "/tmp/ssb-mysql-${container}-all-XXXXXX.sql")
        local zip_file="${dest_dir}/all-databases.sql.gz"
        if ! docker exec \
            -e "MYSQL_PWD=${mysql_pass}" \
            "${container}" \
            mysqldump -u "${mysql_user}" --single-transaction --all-databases \
            > "${tmp_file}"; then
            rm -f "${tmp_file}"
            log_error "  mysqldump (all-databases) failed for container '${container}'"
        else
            if gzip -c "${tmp_file}" > "${zip_file}"; then
                log_info "  Saved: ${zip_file} (gzipped)"
            else
                log_error "  gzip failed for ${tmp_file}"
            fi
            rm -f "${tmp_file}"
        fi
    fi
}

# =============================================================================
# POSTGRESQL BACKUP
#
# Credential discovery (container env vars):
#   1. Label override:
#      - ssb.backup-db-username=<ENV_VAR_NAME>
#      - ssb.backup-db-password=<ENV_VAR_NAME>
#   2. POSTGRES_USER     — defaults to "postgres" if unset
#   3. POSTGRES_PASSWORD — passed as PGPASSWORD; omitted if empty (trust/peer auth)
#
# Recommended production approach: use a .pgpass file or pg_hba.conf trust
# auth for the local socket, or store passwords in Docker Secrets.
#
# Specific databases: set label  ssb.backup-db-names=db1,db2  (uses pg_dump -Fc)
# Full cluster (default):        omit the label                (uses pg_dumpall)
# =============================================================================

backup_postgresql() {
    local container="$1"
    local dest_dir="${DB_BACKUP_DIR}/${container}"
    local db_names_label
    db_names_label=$(get_container_label "${container}" "ssb.backup-db-names")
    local user_env_label
    user_env_label=$(get_container_label "${container}" "ssb.backup-db-username")
    local pass_env_label
    pass_env_label=$(get_container_label "${container}" "ssb.backup-db-password")

    log_info "PostgreSQL backup — container: ${container}"

    local pg_user
    if [[ -n "${user_env_label}" ]]; then
        pg_user=$(get_container_env "${container}" "${user_env_label}")
        if [[ -z "${pg_user}" ]]; then
            log_warn "  Label ssb.backup-db-username='${user_env_label}' is set but env var is missing/empty. Falling back to POSTGRES_USER."
            pg_user=$(get_container_env "${container}" "POSTGRES_USER")
        fi
    else
        pg_user=$(get_container_env "${container}" "POSTGRES_USER")
    fi
    pg_user="${pg_user:-postgres}"

    local pg_pass
    if [[ -n "${pass_env_label}" ]]; then
        pg_pass=$(get_container_env "${container}" "${pass_env_label}")
        if [[ -z "${pg_pass}" ]]; then
            log_warn "  Label ssb.backup-db-password='${pass_env_label}' is set but env var is missing/empty. Falling back to POSTGRES_PASSWORD."
            pg_pass=$(get_container_env "${container}" "POSTGRES_PASSWORD")
        fi
    else
        pg_pass=$(get_container_env "${container}" "POSTGRES_PASSWORD")
    fi

    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "[DRY-RUN] Would pg_dump/pg_dumpall container=${container} user=${pg_user} databases=${db_names_label:-ALL (pg_dumpall)}"
        return 0
    fi

    mkdir -p "${dest_dir}"

    if [[ -n "${db_names_label}" ]]; then
        # Individual database dumps in custom format (restorable with pg_restore)
        IFS=',' read -ra databases <<< "${db_names_label}"
        local db
        for db in "${databases[@]}"; do
            db="${db//[[:space:]]/}"
            [[ -z "${db}" ]] && continue
            log_info "  Dumping database: ${db}"
            local tmp_file
            tmp_file=$(mktemp "/tmp/ssb-pg-${container}-${db}-XXXXXX.dump")
            local zip_file="${dest_dir}/${db}.dump.gz"
            if ! docker exec \
                -e "PGPASSWORD=${pg_pass}" \
                "${container}" \
                pg_dump -U "${pg_user}" -Fc "${db}" \
                > "${tmp_file}"; then
                rm -f "${tmp_file}"
                log_error "  pg_dump failed for database '${db}' in container '${container}'"
            else
                if gzip -c "${tmp_file}" > "${zip_file}"; then
                    log_info "  Saved: ${zip_file} (gzipped)"
                else
                    log_error "  gzip failed for ${tmp_file}"
                fi
                rm -f "${tmp_file}"
            fi
        done
    else
        # Full cluster dump (includes roles, tablespaces, all databases)
        log_info "  Dumping entire PostgreSQL cluster (pg_dumpall)"
        local tmp_file
        tmp_file=$(mktemp "/tmp/ssb-pg-${container}-all-XXXXXX.sql")
        local zip_file="${dest_dir}/pg_dumpall.sql.gz"
        if ! docker exec \
            -e "PGPASSWORD=${pg_pass}" \
            "${container}" \
            pg_dumpall -U "${pg_user}" \
            > "${tmp_file}"; then
            rm -f "${tmp_file}"
            log_error "  pg_dumpall failed for container '${container}'"
        else
            if gzip -c "${tmp_file}" > "${zip_file}"; then
                log_info "  Saved: ${zip_file} (gzipped)"
            else
                log_error "  gzip failed for ${tmp_file}"
            fi
            rm -f "${tmp_file}"
        fi
    fi
}

# =============================================================================
# MONGODB BACKUP
#
# Credential discovery (container env vars):
#   1. Label override:
#      - ssb.backup-db-username=<ENV_VAR_NAME>
#      - ssb.backup-db-password=<ENV_VAR_NAME>
#   2. MONGO_INITDB_ROOT_USERNAME / MONGO_INITDB_ROOT_PASSWORD
#   3. MONGO_USERNAME / MONGO_PASSWORD
#
# Optional label:
#   - ssb.backup-db-auth-db=<auth_db_name> (default: admin)
#
# Specific databases: set label  ssb.backup-db-names=db1,db2
# Full dump (default):          omit the label
# =============================================================================

backup_mongodb() {
    local container="$1"
    local dest_dir="${DB_BACKUP_DIR}/${container}"
    local db_names_label
    db_names_label=$(get_container_label "${container}" "ssb.backup-db-names")
    local user_env_label
    user_env_label=$(get_container_label "${container}" "ssb.backup-db-username")
    local pass_env_label
    pass_env_label=$(get_container_label "${container}" "ssb.backup-db-password")
    local auth_db_label
    auth_db_label=$(get_container_label "${container}" "ssb.backup-db-auth-db")

    log_info "MongoDB backup — container: ${container}"

    local mongo_user=""
    if [[ -n "${user_env_label}" ]]; then
        mongo_user=$(get_container_env "${container}" "${user_env_label}")
        if [[ -z "${mongo_user}" ]]; then
            log_warn "  Label ssb.backup-db-username='${user_env_label}' is set but env var is missing/empty. Falling back to default Mongo env vars."
        fi
    fi
    [[ -z "${mongo_user}" ]] && mongo_user=$(get_container_env "${container}" "MONGO_INITDB_ROOT_USERNAME")
    [[ -z "${mongo_user}" ]] && mongo_user=$(get_container_env "${container}" "MONGO_USERNAME")

    local mongo_pass=""
    if [[ -n "${pass_env_label}" ]]; then
        mongo_pass=$(get_container_env "${container}" "${pass_env_label}")
        if [[ -z "${mongo_pass}" ]]; then
            log_warn "  Label ssb.backup-db-password='${pass_env_label}' is set but env var is missing/empty. Falling back to default Mongo env vars."
        fi
    fi
    [[ -z "${mongo_pass}" ]] && mongo_pass=$(get_container_env "${container}" "MONGO_INITDB_ROOT_PASSWORD")
    [[ -z "${mongo_pass}" ]] && mongo_pass=$(get_container_env "${container}" "MONGO_PASSWORD")

    local mongo_auth_db="${auth_db_label:-admin}"
    local -a auth_args=()
    if [[ -n "${mongo_user}" ]]; then
        auth_args+=(--username "${mongo_user}")
        if [[ -n "${mongo_pass}" ]]; then
            auth_args+=(--password "${mongo_pass}" --authenticationDatabase "${mongo_auth_db}")
        else
            log_warn "  MongoDB username found but password is empty. Attempting mongodump without password."
        fi
    elif [[ -n "${mongo_pass}" ]]; then
        log_warn "  MongoDB password found but username is empty. Attempting mongodump without explicit credentials."
    fi

    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "[DRY-RUN] Would mongodump container=${container} databases=${db_names_label:-ALL} auth_db=${mongo_auth_db}"
        return 0
    fi

    if ! docker exec "${container}" mongodump --version >/dev/null 2>&1; then
        log_error "  mongodump CLI is not available in container '${container}'"
        return 0
    fi

    mkdir -p "${dest_dir}"

    if [[ -n "${db_names_label}" ]]; then
        IFS=',' read -ra databases <<< "${db_names_label}"
        local db
        for db in "${databases[@]}"; do
            db="${db//[[:space:]]/}"
            [[ -z "${db}" ]] && continue
            log_info "  Dumping database: ${db}"
            local tmp_file
            tmp_file=$(mktemp "/tmp/ssb-mongo-${container}-${db}-XXXXXX.archive")
            local zip_file="${dest_dir}/${db}.archive.gz"
            if ! docker exec "${container}" mongodump "${auth_args[@]}" --db "${db}" --archive > "${tmp_file}"; then
                rm -f "${tmp_file}"
                log_error "  mongodump failed for database '${db}' in container '${container}'"
            else
                if gzip -c "${tmp_file}" > "${zip_file}"; then
                    log_info "  Saved: ${zip_file} (gzipped)"
                else
                    log_error "  gzip failed for ${tmp_file}"
                fi
                rm -f "${tmp_file}"
            fi
        done
    else
        log_info "  Dumping all MongoDB databases"
        local tmp_file
        tmp_file=$(mktemp "/tmp/ssb-mongo-${container}-all-XXXXXX.archive")
        local zip_file="${dest_dir}/all-databases.archive.gz"
        if ! docker exec "${container}" mongodump "${auth_args[@]}" --archive > "${tmp_file}"; then
            rm -f "${tmp_file}"
            log_error "  mongodump failed for container '${container}'"
        else
            if gzip -c "${tmp_file}" > "${zip_file}"; then
                log_info "  Saved: ${zip_file} (gzipped)"
            else
                log_error "  gzip failed for ${tmp_file}"
            fi
            rm -f "${tmp_file}"
        fi
    fi
}

# =============================================================================
# SQLITE3 BACKUP
#
# Required label:
#   - ssb.backup-db-path=/path/to/database.sqlite
#
# The dump is created with sqlite3's .dump command and stored as:
#   <container>/<db-name>.sql.gz
# =============================================================================

backup_sqlite3() {
    local container="$1"
    local dest_dir="${DB_BACKUP_DIR}/${container}"
    local sqlite_path
    sqlite_path=$(get_container_label "${container}" "ssb.backup-db-path")

    log_info "SQLite3 backup — container: ${container}"

    if [[ -z "${sqlite_path}" ]]; then
        log_error "  Label ssb.backup-db-path is required for sqlite3 backup on container '${container}'"
        return 0
    fi

    local sqlite_base
    sqlite_base=$(basename "${sqlite_path}")
    local sqlite_name="${sqlite_base%.*}"
    [[ -z "${sqlite_name}" ]] && sqlite_name="database"

    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "[DRY-RUN] Would sqlite3 dump container=${container} file=${sqlite_path} output=${dest_dir}/${sqlite_name}.sql.gz"
        return 0
    fi

    if ! docker exec "${container}" test -f "${sqlite_path}" >/dev/null 2>&1; then
        log_error "  SQLite file not found in container '${container}': ${sqlite_path}"
        return 0
    fi

    mkdir -p "${dest_dir}"

    local tmp_file
    tmp_file=$(mktemp "/tmp/ssb-sqlite-${container}-${sqlite_name}-XXXXXX.sql")
    local zip_file="${dest_dir}/${sqlite_name}.sql.gz"
    local err_file
    err_file=$(mktemp "/tmp/ssb-sqlite-${container}-${sqlite_name}-XXXXXX.err")
    local copied_db
    copied_db=$(mktemp "/tmp/ssb-sqlite-${container}-${sqlite_name}-XXXXXX.db")

    # Preferred path: run sqlite3 inside the container.
    if docker exec "${container}" sqlite3 -version >/dev/null 2>&1; then
        if ! docker exec "${container}" sqlite3 -readonly -cmd '.timeout 5000' "${sqlite_path}" .dump > "${tmp_file}" 2> "${err_file}"; then
            local err_msg
            err_msg=$(tr '\n' ' ' < "${err_file}" | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//')
            rm -f "${tmp_file}"
            rm -f "${err_file}"
            rm -f "${copied_db}"
            if [[ -n "${err_msg}" ]]; then
                log_error "  sqlite3 dump failed for '${sqlite_path}' in container '${container}': ${err_msg}"
            else
                log_error "  sqlite3 dump failed for '${sqlite_path}' in container '${container}'"
            fi
            return 0
        fi
        rm -f "${err_file}"
    else
        # Fallback path: copy DB file to host and dump with host sqlite3.
        log_warn "  sqlite3 CLI is not available in container '${container}' — falling back to host sqlite3 via docker cp"

        if ! command -v sqlite3 >/dev/null 2>&1; then
            rm -f "${tmp_file}" "${err_file}" "${copied_db}"
            log_error "  sqlite3 CLI not found on host; install sqlite3 on host or in container '${container}'"
            return 0
        fi

        if ! docker cp "${container}:${sqlite_path}" "${copied_db}" 2> "${err_file}"; then
            local cp_err
            cp_err=$(tr '\n' ' ' < "${err_file}" | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//')
            rm -f "${tmp_file}" "${err_file}" "${copied_db}"
            log_error "  Failed to copy SQLite file from container '${container}': ${cp_err:-docker cp failed}"
            return 0
        fi

        if ! sqlite3 -readonly -cmd '.timeout 5000' "${copied_db}" .dump > "${tmp_file}" 2> "${err_file}"; then
            local host_err
            host_err=$(tr '\n' ' ' < "${err_file}" | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//')
            rm -f "${tmp_file}" "${err_file}" "${copied_db}"
            log_error "  Host sqlite3 dump failed for copied file from '${container}:${sqlite_path}': ${host_err:-sqlite3 dump failed}"
            return 0
        fi
        rm -f "${err_file}" "${copied_db}"
    fi

    if gzip -c "${tmp_file}" > "${zip_file}"; then
        log_info "  Saved: ${zip_file} (gzipped)"
    else
        log_error "  gzip failed for ${tmp_file}"
    fi
    rm -f "${tmp_file}"
}

# =============================================================================
# DATABASE BACKUP DISPATCHER
# =============================================================================

backup_databases() {
    local containers
    containers=$(get_local_containers)

    if [[ -z "${containers}" ]]; then
        log_info "No running containers found on this node — skipping database backup."
        return 0
    fi

    log_info "Checking containers for database backup labels..."

    local container
    while IFS= read -r container; do
        [[ -z "${container}" ]] && continue
        local db_type
        db_type=$(get_container_label "${container}" "ssb.backup-db")
        # Normalize to lowercase (requires bash 4.0+)
        db_type="${db_type,,}"
        case "${db_type}" in
            mysql|mariadb)
                backup_mysql "${container}" || true
                ;;
            postgresql|postgres)
                backup_postgresql "${container}" || true
                ;;
            mongodb|mongo)
                backup_mongodb "${container}" || true
                ;;
            sqlite3|sqlite)
                backup_sqlite3 "${container}" || true
                ;;
            "")
                # No backup label — skip silently
                ;;
            *)
                log_warn "Unknown ssb.backup-db value '${db_type}' on container '${container}' — skipping."
                ;;
        esac
    done <<< "${containers}"
}

# =============================================================================
# DOCKER FILE BACKUP
# =============================================================================

backup_docker_files() {
    local src="$1"
    local dest="$2"

    log_info "Backing up Docker files: ${src} → ${dest}"

    local exclude_args=()
    for exclude in "${DOCKER_EXCLUDE_DIRS[@]}"; do
        exclude_args+=("--exclude=${exclude}")
    done

    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "[DRY-RUN] Would rsync ${src} to ${dest} with exclusions: ${exclude_args[*]}"
        return 0
    fi

    rsync -av --delete "${exclude_args[@]}" "${src}/" "${dest}/"
}

# =============================================================================
# GLUSTERFS BACKUP
# =============================================================================

backup_gluster() {
    if [[ "${BACKUP_GLUSTER}" != "true" ]]; then
        log_info "GlusterFS backup disabled on this node (BACKUP_GLUSTER=false) — skipping."
        return 0
    fi

    if [[ ! -d "${GLUSTER_SRC}" ]]; then
        log_warn "GlusterFS source '${GLUSTER_SRC}' not found — skipping."
        return 0
    fi

    log_info "Backing up GlusterFS: ${GLUSTER_SRC} → ${GLUSTER_BACKUP_DIR}"

    local -a exclude_args=()
    local excl
    for excl in "${GLUSTER_EXCLUDE_DIRS[@]}"; do
        exclude_args+=("--exclude=${excl}")
    done

    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "[DRY-RUN] Would create: ${GLUSTER_BACKUP_DIR}"
        log_info "[DRY-RUN] Would run: rsync -av --delete ${exclude_args[*]+"${exclude_args[*]}"} ${GLUSTER_SRC}/ ${GLUSTER_BACKUP_DIR}/"
        return 0
    fi

    mkdir -p "${GLUSTER_BACKUP_DIR}"

    if ! rsync -av --delete \
            ${exclude_args[@]+"${exclude_args[@]}"} \
            "${GLUSTER_SRC}/" "${GLUSTER_BACKUP_DIR}/" \
            2>&1 | tee -a "${LOG_FILE}"; then
        log_error "rsync of GlusterFS failed"
    else
        log_info "GlusterFS backup complete."
    fi
}

# =============================================================================
# RETENTION / CLEANUP
# =============================================================================

cleanup_old_backups() {
    # Per-host backup retention
    local host_root="${BACKUP_BASE}/${SHORT_HOSTNAME}"
    local cutoff_date
    cutoff_date=$(date -d "${RETENTION_DAYS} days ago" +%Y-%m-%d 2>/dev/null) \
        || cutoff_date=$(date -v "-${RETENTION_DAYS}d" +%Y-%m-%d 2>/dev/null) \
        || { log_warn "Could not compute retention cutoff — skipping cleanup."; return 0; }

    log_info "Retention: removing per-host backups on or before ${cutoff_date} (>="${RETENTION_DAYS}" days) in ${host_root}"
    local found=0
    local dir dir_date
    while IFS= read -r dir; do
        dir_date=$(basename "${dir}")
        if [[ "${dir_date}" < "${cutoff_date}" || "${dir_date}" == "${cutoff_date}" ]]; then
            found=$((found + 1))
            if [[ "${DRY_RUN}" == "true" ]]; then
                log_info "[DRY-RUN] Would remove: ${dir}"
            else
                log_info "  Removing: ${dir}"
                rm -rf "${dir}"
            fi
        fi
    done < <(find "${host_root}" -maxdepth 1 -mindepth 1 -type d -name "????-??-??" 2>/dev/null || true)
    [[ "${found}" -eq 0 ]] && log_info "  No old backups to remove."

    # GlusterFS backup retention (only on designated node)
    if [[ "${BACKUP_GLUSTER}" == "true" ]]; then
        local gluster_root="${BACKUP_BASE}/${GLUSTER_DEST_NAME}"
        log_info "Retention: removing GlusterFS backups on or before ${cutoff_date} (>="${RETENTION_DAYS}" days) in ${gluster_root}"
        local gfound=0
        while IFS= read -r dir; do
            dir_date=$(basename "${dir}")
            if [[ "${dir_date}" < "${cutoff_date}" || "${dir_date}" == "${cutoff_date}" ]]; then
                gfound=$((gfound + 1))
                if [[ "${DRY_RUN}" == "true" ]]; then
                    log_info "[DRY-RUN] Would remove: ${dir}"
                else
                    log_info "  Removing: ${dir}"
                    rm -rf "${dir}"
                fi
            fi
        done < <(find "${gluster_root}" -maxdepth 1 -mindepth 1 -type d -name "????-??-??" 2>/dev/null || true)
        [[ "${gfound}" -eq 0 ]] && log_info "  No old GlusterFS backups to remove."
    fi
}

# =============================================================================
# HEALTHCHECK
# =============================================================================

send_healthcheck() {
    [[ -z "${HEALTHCHECK_URL}" ]] && return 0

    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "[DRY-RUN] Would send healthcheck ping to: ${HEALTHCHECK_URL}"
        return 0
    fi

    log_info "Sending healthcheck ping: ${HEALTHCHECK_URL}"
    if ! curl -fsS --max-time 10 "${HEALTHCHECK_URL}" > /dev/null 2>&1; then
        log_warn "Healthcheck ping failed (non-fatal)."
    fi
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    parse_args "$@"
    load_config
    set_runtime_paths

    # Ensure the log directory exists before the first log call (non-dry-run)
    if [[ "${DRY_RUN}" != "true" ]]; then
        if [[ ! -d "${BACKUP_BASE}" ]]; then
            echo "ERROR: Backup base '${BACKUP_BASE}' is not accessible." >&2
            exit 1
        fi
        mkdir -p "${HOST_BACKUP_DIR}" 2>/dev/null || true
    fi

    log_info "========================================================"
    log_info "SSB — Simple Swarm Backup"
    log_info "Host     : ${SHORT_HOSTNAME}"
    log_info "Date     : ${DATE}"
    log_info "Dry-run  : ${DRY_RUN}"
    log_info "Config   : ${CONFIG_FILE}"
    log_info "Backup to: ${HOST_BACKUP_DIR}"
    log_info "========================================================"

    check_prerequisites

    acquire_lock
    # Always release the lock on exit (normal or abnormal)
    trap 'release_lock' EXIT

    setup_dirs
    backup_docker_files "${DOCKER_SRC}" "${DOCKER_BACKUP_DIR}"
    backup_databases
    backup_gluster
    cleanup_old_backups

    if [[ "${ERRORS}" -gt 0 ]]; then
        log_error "Backup finished with ${ERRORS} error(s) — review ${LOG_FILE}"
        exit 1
    fi

    log_info "Backup completed successfully with no errors."
    send_healthcheck
    exit 0
}

main "$@"
