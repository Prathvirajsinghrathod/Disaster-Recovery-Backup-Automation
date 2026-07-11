#!/usr/bin/env bash
#
# restore_from_backup.sh — Restore a database from an S3 backup
#
# Safety features:
#   - Defaults to LATEST backup but accepts an explicit --file
#   - Requires --confirm flag to actually execute (dry-run by default)
#   - Verifies checksum before restoring
#   - Takes a pre-restore snapshot of the target DB (if it exists) so a bad
#     restore can itself be rolled back
#
# Usage:
#   ./restore_from_backup.sh --target-db app_staging                # dry-run, shows plan
#   ./restore_from_backup.sh --target-db app_staging --confirm       # executes
#   ./restore_from_backup.sh --target-db app_staging --file app_production_20260710T030000Z.sql.gz --confirm
#
set -euo pipefail
IFS=$'\n\t'

DB_ENGINE="${DB_ENGINE:-postgres}"
DB_HOST="${DB_HOST:-localhost}"
DB_PORT="${DB_PORT:-5432}"
DB_USER="${DB_USER:-backup_user}"
DB_PASSWORD="${DB_PASSWORD:?ERROR: DB_PASSWORD must be set}"
S3_BUCKET="${S3_BUCKET:-my-org-db-backups}"
S3_PREFIX="${S3_PREFIX:-app_production}"
AWS_REGION="${AWS_REGION:-us-east-1}"
WORK_DIR="${WORK_DIR:-/tmp/db_restore}"

TARGET_DB=""
BACKUP_FILE=""
CONFIRM="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target-db) TARGET_DB="$2"; shift 2 ;;
    --file) BACKUP_FILE="$2"; shift 2 ;;
    --confirm) CONFIRM="true"; shift ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done

if [[ -z "${TARGET_DB}" ]]; then
  echo "ERROR: --target-db is required"; exit 1
fi

mkdir -p "${WORK_DIR}"

echo "== Disaster Recovery: Database Restore =="
echo "Target DB : ${TARGET_DB}"
echo "Engine    : ${DB_ENGINE}"
echo "Mode      : $([[ "${CONFIRM}" == "true" ]] && echo EXECUTE || echo DRY-RUN)"
echo

# ---------------------------------------------------------------------------
# 1. Identify backup file (latest if not specified)
# ---------------------------------------------------------------------------
if [[ -z "${BACKUP_FILE}" ]]; then
  echo "No --file specified, locating latest backup in s3://${S3_BUCKET}/${S3_PREFIX}/ ..."
  BACKUP_FILE=$(aws s3api list-objects-v2 --bucket "${S3_BUCKET}" --prefix "${S3_PREFIX}/" \
    --query "sort_by(Contents[?ends_with(Key,'.sql.gz')], &LastModified)[-1].Key" \
    --output text --region "${AWS_REGION}")
  BACKUP_FILE="${BACKUP_FILE##*/}"
fi

if [[ -z "${BACKUP_FILE}" || "${BACKUP_FILE}" == "None" ]]; then
  echo "ERROR: No backup file found."; exit 1
fi
echo "Selected backup: ${BACKUP_FILE}"

# ---------------------------------------------------------------------------
# 2. Download + verify checksum
# ---------------------------------------------------------------------------
LOCAL_PATH="${WORK_DIR}/${BACKUP_FILE}"
echo "Downloading backup and checksum..."
aws s3 cp "s3://${S3_BUCKET}/${S3_PREFIX}/${BACKUP_FILE}" "${LOCAL_PATH}" --region "${AWS_REGION}"
aws s3 cp "s3://${S3_BUCKET}/${S3_PREFIX}/${BACKUP_FILE}.sha256" "${LOCAL_PATH}.sha256" --region "${AWS_REGION}" || \
  echo "WARN: no checksum file found, skipping verification"

if [[ -f "${LOCAL_PATH}.sha256" ]]; then
  echo "Verifying checksum..."
  (cd "${WORK_DIR}" && sha256sum -c "${BACKUP_FILE}.sha256")
fi

gzip -t "${LOCAL_PATH}" || { echo "ERROR: downloaded archive failed integrity check"; exit 1; }

if [[ "${CONFIRM}" != "true" ]]; then
  echo
  echo "DRY-RUN complete. Backup ${BACKUP_FILE} is valid and ready to restore."
  echo "Re-run with --confirm to execute the restore against '${TARGET_DB}'."
  exit 0
fi

# ---------------------------------------------------------------------------
# 3. Pre-restore safety snapshot of target DB (if it currently exists)
# ---------------------------------------------------------------------------
case "${DB_ENGINE}" in
  postgres)
    export PGPASSWORD="${DB_PASSWORD}"
    DB_EXISTS=$(psql -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USER}" -tAc \
      "SELECT 1 FROM pg_database WHERE datname='${TARGET_DB}'")
    if [[ "${DB_EXISTS}" == "1" ]]; then
      SAFETY_FILE="${WORK_DIR}/pre_restore_safety_$(date -u +%Y%m%dT%H%M%SZ).sql.gz"
      echo "Target DB exists — taking pre-restore safety snapshot: ${SAFETY_FILE}"
      pg_dump -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USER}" -d "${TARGET_DB}" | gzip -9 > "${SAFETY_FILE}"
      echo "Safety snapshot saved locally. Dropping and recreating ${TARGET_DB}..."
      dropdb -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USER}" "${TARGET_DB}"
    fi
    createdb -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USER}" "${TARGET_DB}"
    echo "Restoring ${BACKUP_FILE} into ${TARGET_DB}..."
    gunzip -c "${LOCAL_PATH}" | psql -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USER}" -d "${TARGET_DB}"
    ;;
  mysql)
    SAFETY_FILE="${WORK_DIR}/pre_restore_safety_$(date -u +%Y%m%dT%H%M%SZ).sql.gz"
    echo "Taking pre-restore safety snapshot: ${SAFETY_FILE}"
    mysqldump -h "${DB_HOST}" -P "${DB_PORT}" -u "${DB_USER}" -p"${DB_PASSWORD}" "${TARGET_DB}" \
      | gzip -9 > "${SAFETY_FILE}" || echo "WARN: target DB may not exist yet, continuing"
    echo "Restoring ${BACKUP_FILE} into ${TARGET_DB}..."
    gunzip -c "${LOCAL_PATH}" | mysql -h "${DB_HOST}" -P "${DB_PORT}" -u "${DB_USER}" -p"${DB_PASSWORD}" "${TARGET_DB}"
    ;;
  *)
    echo "ERROR: Unsupported DB_ENGINE: ${DB_ENGINE}"; exit 1 ;;
esac

echo
echo "== Restore complete =="
echo "Restored ${BACKUP_FILE} into ${TARGET_DB}"
echo "Run application-level smoke tests now before routing production traffic."
