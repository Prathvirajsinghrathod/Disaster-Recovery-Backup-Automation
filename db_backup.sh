#!/usr/bin/env bash
#
# db_backup.sh — Automated logical backup for Postgres or MySQL
#
# Features:
#   - Works with Postgres (pg_dump) or MySQL (mysqldump)
#   - Compresses, checksums, and uploads to S3
#   - Enforces local + remote retention policy
#   - Verifies backup integrity before declaring success
#   - Sends Slack/webhook alert on failure (and optionally on success)
#
# Usage:
#   ./db_backup.sh
#
# Configure via environment variables (or a sourced .env file) — see CONFIG section.
#
set -euo pipefail
IFS=$'\n\t'

# ---------------------------------------------------------------------------
# CONFIG — override via environment or a .env file sourced before this script
# ---------------------------------------------------------------------------
DB_ENGINE="${DB_ENGINE:-postgres}"          # postgres | mysql
DB_HOST="${DB_HOST:-localhost}"
DB_PORT="${DB_PORT:-5432}"
DB_NAME="${DB_NAME:-app_production}"
DB_USER="${DB_USER:-backup_user}"
# DB_PASSWORD should come from a secrets manager, not hardcoded. Example:
#   export DB_PASSWORD=$(aws secretsmanager get-secret-value --secret-id db/backup-user --query SecretString --output text)
DB_PASSWORD="${DB_PASSWORD:?ERROR: DB_PASSWORD must be set (use a secrets manager)}"

BACKUP_DIR="${BACKUP_DIR:-/var/backups/db}"
S3_BUCKET="${S3_BUCKET:-my-org-db-backups}"
S3_PREFIX="${S3_PREFIX:-${DB_NAME}}"
AWS_REGION="${AWS_REGION:-us-east-1}"

LOCAL_RETENTION_DAYS="${LOCAL_RETENTION_DAYS:-3}"
S3_DAILY_RETENTION_DAYS="${S3_DAILY_RETENTION_DAYS:-35}"      # S3 lifecycle handles long-term tiers (see terraform)

SLACK_WEBHOOK_URL="${SLACK_WEBHOOK_URL:-}"                    # optional
NOTIFY_ON_SUCCESS="${NOTIFY_ON_SUCCESS:-false}"

TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
HOSTNAME_TAG="$(hostname -s)"
BACKUP_FILE="${DB_NAME}_${TIMESTAMP}.sql.gz"
BACKUP_PATH="${BACKUP_DIR}/${BACKUP_FILE}"
CHECKSUM_PATH="${BACKUP_PATH}.sha256"
LOG_FILE="${BACKUP_DIR}/backup_${TIMESTAMP}.log"

mkdir -p "${BACKUP_DIR}"

# ---------------------------------------------------------------------------
# LOGGING / ALERTING
# ---------------------------------------------------------------------------
log() {
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" | tee -a "${LOG_FILE}"
}

notify() {
  local status="$1" message="$2"
  log "${status}: ${message}"
  if [[ -n "${SLACK_WEBHOOK_URL}" ]]; then
    if [[ "${status}" == "FAILURE" || "${NOTIFY_ON_SUCCESS}" == "true" ]]; then
      curl -sf -X POST -H 'Content-type: application/json' \
        --data "{\"text\": \"[${status}] DB Backup (${HOSTNAME_TAG}/${DB_NAME}): ${message}\"}" \
        "${SLACK_WEBHOOK_URL}" >/dev/null || log "WARN: Slack notification failed"
    fi
  fi
}

trap 'notify "FAILURE" "Backup script exited unexpectedly at line $LINENO"' ERR

# ---------------------------------------------------------------------------
# BACKUP
# ---------------------------------------------------------------------------
log "Starting backup: engine=${DB_ENGINE} db=${DB_NAME} host=${DB_HOST}"

case "${DB_ENGINE}" in
  postgres)
    export PGPASSWORD="${DB_PASSWORD}"
    # -Fc = custom format (compressed, supports parallel restore); piping through gzip on top
    # for the plain-SQL fallback path. Adjust to pg_dump -Fc if you prefer pg_restore workflows.
    pg_dump -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USER}" -d "${DB_NAME}" \
      --no-owner --no-privileges --format=plain \
      | gzip -9 > "${BACKUP_PATH}"
    ;;
  mysql)
    mysqldump -h "${DB_HOST}" -P "${DB_PORT}" -u "${DB_USER}" -p"${DB_PASSWORD}" \
      --single-transaction --quick --routines --triggers --events "${DB_NAME}" \
      | gzip -9 > "${BACKUP_PATH}"
    ;;
  *)
    notify "FAILURE" "Unsupported DB_ENGINE: ${DB_ENGINE}"
    exit 1
    ;;
esac

if [[ ! -s "${BACKUP_PATH}" ]]; then
  notify "FAILURE" "Backup file is empty or missing: ${BACKUP_PATH}"
  exit 1
fi

# ---------------------------------------------------------------------------
# VERIFY (checksum + gzip integrity)
# ---------------------------------------------------------------------------
log "Verifying backup integrity"
gzip -t "${BACKUP_PATH}" || { notify "FAILURE" "gzip integrity check failed"; exit 1; }
sha256sum "${BACKUP_PATH}" > "${CHECKSUM_PATH}"

BACKUP_SIZE=$(du -h "${BACKUP_PATH}" | cut -f1)
log "Backup verified. Size: ${BACKUP_SIZE}"

# ---------------------------------------------------------------------------
# UPLOAD TO S3 (encrypted at rest via bucket default SSE — see terraform)
# ---------------------------------------------------------------------------
log "Uploading to s3://${S3_BUCKET}/${S3_PREFIX}/"
aws s3 cp "${BACKUP_PATH}" "s3://${S3_BUCKET}/${S3_PREFIX}/${BACKUP_FILE}" \
  --region "${AWS_REGION}" --storage-class STANDARD_IA \
  || { notify "FAILURE" "S3 upload failed for ${BACKUP_FILE}"; exit 1; }

aws s3 cp "${CHECKSUM_PATH}" "s3://${S3_BUCKET}/${S3_PREFIX}/${BACKUP_FILE}.sha256" \
  --region "${AWS_REGION}" \
  || log "WARN: checksum upload failed (non-fatal)"

# Verify the object actually landed and matches expected size
REMOTE_SIZE=$(aws s3api head-object --bucket "${S3_BUCKET}" --key "${S3_PREFIX}/${BACKUP_FILE}" \
  --query ContentLength --output text --region "${AWS_REGION}")
LOCAL_SIZE=$(stat -c%s "${BACKUP_PATH}" 2>/dev/null || stat -f%z "${BACKUP_PATH}")
if [[ "${REMOTE_SIZE}" != "${LOCAL_SIZE}" ]]; then
  notify "FAILURE" "Size mismatch after upload: local=${LOCAL_SIZE} remote=${REMOTE_SIZE}"
  exit 1
fi

# ---------------------------------------------------------------------------
# RETENTION — prune old local and S3 backups
# ---------------------------------------------------------------------------
log "Pruning local backups older than ${LOCAL_RETENTION_DAYS} days"
find "${BACKUP_DIR}" -name "${DB_NAME}_*.sql.gz*" -mtime "+${LOCAL_RETENTION_DAYS}" -delete
find "${BACKUP_DIR}" -name "backup_*.log" -mtime "+${LOCAL_RETENTION_DAYS}" -delete

log "Pruning S3 backups older than ${S3_DAILY_RETENTION_DAYS} days (belt-and-braces; lifecycle policy also handles this)"
CUTOFF=$(date -u -d "-${S3_DAILY_RETENTION_DAYS} days" +%Y-%m-%d 2>/dev/null || date -u -v-"${S3_DAILY_RETENTION_DAYS}"d +%Y-%m-%d)
aws s3api list-objects-v2 --bucket "${S3_BUCKET}" --prefix "${S3_PREFIX}/" \
  --query "Contents[?LastModified<='${CUTOFF}'].Key" --output text --region "${AWS_REGION}" \
  | tr '\t' '\n' | while read -r key; do
    [[ -z "${key}" || "${key}" == "None" ]] && continue
    aws s3 rm "s3://${S3_BUCKET}/${key}" --region "${AWS_REGION}"
    log "Deleted expired backup: ${key}"
  done

notify "SUCCESS" "Backup completed: ${BACKUP_FILE} (${BACKUP_SIZE}) uploaded to S3"
log "Backup job complete."
