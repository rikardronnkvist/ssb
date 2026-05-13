#!/usr/bin/env bash
# =============================================================================
# ssb.sh — Simple Swarm Backup
#
# Backs up local Docker container volumes and databases on each Swarm node.
# Designed to run from cron on each node independently; no central scheduler.
#
# Usage: ssb.sh [--dry-run] [--help]
# =============================================================================

set -uo pipefail

# =============================================================================
# CONFIGURATION — Edit these values to match your environment
# =============================================================================

# Base directory of the (NFS-mounted) backup target
BACKUP_BASE="/mnt/nas01backup"

# Source directory containing Docker bind-mount data
DOCKER_SRC="/srv/docker"

# GlusterFS source directory (replicated across all Swarm nodes)
GLUSTER_SRC="/mnt/gluster01"

# Set to "true" on exactly ONE node that should back up GlusterFS.
# All other nodes must leave this as "false".
BACKUP_GLUSTER="false"

# Output folder name for GlusterFS backups under BACKUP_BASE
GLUSTER_DEST_NAME="gluster01"

# Number of days to retain per-host dated backup directories.
# Directories older than this are removed after a successful backup.
RETENTION_DAYS=5

# What to do when a dated backup directory already exists for today:
#   "overwrite"  — continue the run, overwriting existing files
#   "keep"       — exit without making any changes
EXISTING_BACKUP_ACTION="overwrite"

# Paths relative to DOCKER_SRC to exclude from the rsync backup.
# Example: DOCKER_EXCLUDE_DIRS=("service-a/cache" "service-b/tmp")
DOCKER_EXCLUDE_DIRS=()

# URL to ping (via curl) on a fully successful backup run.
# Leave empty to disable.  Example: "https://hc-ping.com/<uuid>"
HEALTHCHECK_URL=""

# =============================================================================
# INTERNAL — Do not edit below this line unless you know what you are doing
# =============================================================================

DATE=$(date +%Y-%m-%d)
readonly DATE

SHORT_HOSTNAME=$(hostname -s)
readonly SHORT_HOSTNAME

HOST_BACKUP_DIR="${BACKUP_BASE}/${SHORT_HOSTNAME}/${DATE}"
LOCK_FILE="${BACKUP_BASE}/${SHORT_HOSTNAME}/backup-${DATE}.lock"
LOG_FILE="${HOST_BACKUP_DIR}/backup.log"
DOCKER_BACKUP_DIR="${HOST_BACKUP_DIR}/docker"
DB_BACKUP_DIR="${HOST_BACKUP_DIR}/databases"
GLUSTER_BACKUP_DIR="${BACKUP_BASE}/${GLUSTER_DEST_NAME}/${DATE}"

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
  --dry-run    Show what would be done without writing any files
  --help       Show this help message

Exit codes:
  0   All backup tasks completed successfully
  1   One or more backup tasks failed
  2   Invalid arguments
EOF
    exit 0
}

parse_args() {
    for arg in "$@"; do
        case "${arg}" in
            --dry-run|-n) DRY_RUN="true" ;;
            --help|-h)    usage ;;
            *)
                echo "Unknown argument: ${arg}" >&2
                echo "Run '$(basename "$0") --help' for usage." >&2
                exit 2
                ;;
        esac
    done
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
    for cmd in docker rsync curl; do
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
        log_info "[DRY-RUN] Would create: ${DB_BACKUP_DIR}"
        return 0
    fi

    if [[ -d "${HOST_BACKUP_DIR}" ]] && [[ "${EXISTING_BACKUP_ACTION}" == "keep" ]]; then
        log_info "Backup for ${DATE} already exists and EXISTING_BACKUP_ACTION=keep — exiting."
        release_lock
        exit 0
    fi

    mkdir -p "${DOCKER_BACKUP_DIR}"
    mkdir -p "${DB_BACKUP_DIR}"
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
#   1. MYSQL_ROOT_PASSWORD or MARIADB_ROOT_PASSWORD  → user root
#   2. MYSQL_PASSWORD or MARIADB_PASSWORD            → MYSQL_USER / MARIADB_USER
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

    log_info "MySQL/MariaDB backup — container: ${container}"

    # Resolve credentials from container environment
    local mysql_user="root"
    local mysql_pass=""

    local env_var
    for env_var in MYSQL_ROOT_PASSWORD MARIADB_ROOT_PASSWORD; do
        mysql_pass=$(get_container_env "${container}" "${env_var}")
        if [[ -n "${mysql_pass}" ]]; then
            mysql_user="root"
            break
        fi
    done

    if [[ -z "${mysql_pass}" ]]; then
        for env_var in MYSQL_PASSWORD MARIADB_PASSWORD; do
            mysql_pass=$(get_container_env "${container}" "${env_var}")
            if [[ -n "${mysql_pass}" ]]; then
                local u
                u=$(get_container_env "${container}" "MYSQL_USER")
                [[ -z "${u}" ]] && u=$(get_container_env "${container}" "MARIADB_USER")
                mysql_user="${u:-root}"
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
            local out_file="${dest_dir}/${db}.sql"
            if ! docker exec \
                -e "MYSQL_PWD=${mysql_pass}" \
                "${container}" \
                mysqldump -u "${mysql_user}" --single-transaction --quick "${db}" \
                > "${out_file}"; then
                rm -f "${out_file}"
                log_error "  mysqldump failed for database '${db}' in container '${container}'"
            else
                log_info "  Saved: ${out_file}"
            fi
        done
    else
        # Full cluster dump
        log_info "  Dumping all databases"
        local out_file="${dest_dir}/all-databases.sql"
        if ! docker exec \
            -e "MYSQL_PWD=${mysql_pass}" \
            "${container}" \
            mysqldump -u "${mysql_user}" --single-transaction --all-databases \
            > "${out_file}"; then
            rm -f "${out_file}"
            log_error "  mysqldump (all-databases) failed for container '${container}'"
        else
            log_info "  Saved: ${out_file}"
        fi
    fi
}

# =============================================================================
# POSTGRESQL BACKUP
#
# Credential discovery (container env vars):
#   POSTGRES_USER     — defaults to "postgres" if unset
#   POSTGRES_PASSWORD — passed as PGPASSWORD; omitted if empty (trust/peer auth)
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

    log_info "PostgreSQL backup — container: ${container}"

    local pg_user
    pg_user=$(get_container_env "${container}" "POSTGRES_USER")
    pg_user="${pg_user:-postgres}"

    local pg_pass
    pg_pass=$(get_container_env "${container}" "POSTGRES_PASSWORD")

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
            local out_file="${dest_dir}/${db}.dump"
            if ! docker exec \
                -e "PGPASSWORD=${pg_pass}" \
                "${container}" \
                pg_dump -U "${pg_user}" -Fc "${db}" \
                > "${out_file}"; then
                rm -f "${out_file}"
                log_error "  pg_dump failed for database '${db}' in container '${container}'"
            else
                log_info "  Saved: ${out_file}"
            fi
        done
    else
        # Full cluster dump (includes roles, tablespaces, all databases)
        log_info "  Dumping entire PostgreSQL cluster (pg_dumpall)"
        local out_file="${dest_dir}/pg_dumpall.sql"
        if ! docker exec \
            -e "PGPASSWORD=${pg_pass}" \
            "${container}" \
            pg_dumpall -U "${pg_user}" \
            > "${out_file}"; then
            rm -f "${out_file}"
            log_error "  pg_dumpall failed for container '${container}'"
        else
            log_info "  Saved: ${out_file}"
        fi
    fi
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
    if [[ ! -d "${DOCKER_SRC}" ]]; then
        log_warn "Docker source '${DOCKER_SRC}' not found — skipping file backup."
        return 0
    fi

    log_info "Backing up Docker files: ${DOCKER_SRC} → ${DOCKER_BACKUP_DIR}"

    local -a exclude_args=()
    local excl
    for excl in "${DOCKER_EXCLUDE_DIRS[@]}"; do
        exclude_args+=("--exclude=${excl}")
    done

    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "[DRY-RUN] Would run: rsync -av --delete ${exclude_args[*]+"${exclude_args[*]}"} ${DOCKER_SRC}/ ${DOCKER_BACKUP_DIR}/"
        return 0
    fi

    if ! rsync -av --delete \
            ${exclude_args[@]+"${exclude_args[@]}"} \
            "${DOCKER_SRC}/" "${DOCKER_BACKUP_DIR}/" \
            2>&1 | tee -a "${LOG_FILE}"; then
        log_error "rsync of Docker files failed"
    else
        log_info "Docker file backup complete."
    fi
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

    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "[DRY-RUN] Would create: ${GLUSTER_BACKUP_DIR}"
        log_info "[DRY-RUN] Would run: rsync -av --delete ${GLUSTER_SRC}/ ${GLUSTER_BACKUP_DIR}/"
        return 0
    fi

    mkdir -p "${GLUSTER_BACKUP_DIR}"

    if ! rsync -av --delete \
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
    local host_root="${BACKUP_BASE}/${SHORT_HOSTNAME}"

    # Compute cutoff date (GNU date; falls back to BSD date on macOS)
    local cutoff_date
    cutoff_date=$(date -d "${RETENTION_DAYS} days ago" +%Y-%m-%d 2>/dev/null) \
        || cutoff_date=$(date -v "-${RETENTION_DAYS}d" +%Y-%m-%d 2>/dev/null) \
        || { log_warn "Could not compute retention cutoff — skipping cleanup."; return 0; }

    log_info "Retention: removing per-host backups before ${cutoff_date} (>${RETENTION_DAYS} days) in ${host_root}"

    local found=0
    local dir dir_date
    while IFS= read -r dir; do
        dir_date=$(basename "${dir}")
        # ISO date string comparison is lexicographically correct
        if [[ "${dir_date}" < "${cutoff_date}" ]]; then
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
    log_info "Backup to: ${HOST_BACKUP_DIR}"
    log_info "========================================================"

    check_prerequisites

    acquire_lock
    # Always release the lock on exit (normal or abnormal)
    trap 'release_lock' EXIT

    setup_dirs
    backup_docker_files
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
