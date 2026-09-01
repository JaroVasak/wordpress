#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/validation.sh
source "$REPO_DIR/scripts/lib/validation.sh"

require_command docker
require_command gzip

if (( $# < 1 || $# > 2 )); then
  die "Usage: $0 <site-name> [backup-root]"
fi

SITE_NAME="$1"
BACKUP_ROOT="${2:-$REPO_DIR/backups}"
BACKUP_RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-14}"

is_valid_site_name "$SITE_NAME" || \
  die "Use a lowercase site slug with letters, digits, and single hyphens."
is_positive_integer "$BACKUP_RETENTION_DAYS" || \
  die "BACKUP_RETENTION_DAYS must be a positive integer."

SITE_DIR="$REPO_DIR/sites/$SITE_NAME"
SITE_ENV="$SITE_DIR/.env"
[ -d "$SITE_DIR" ] || die "Site directory not found: $SITE_DIR"
[ -f "$SITE_ENV" ] || die "Site environment file not found: $SITE_ENV"

DB_NAME=$(sed -n 's/^DB_NAME=//p' "$SITE_ENV" | tail -n 1)
is_valid_db_name "$DB_NAME" || die "DB_NAME in $SITE_ENV is invalid."

MARIADB_RUNNING=$(docker inspect --format '{{.State.Running}}' mariadb \
  2>/dev/null || true)
[[ "$MARIADB_RUNNING" == "true" ]] || die "MariaDB is not running."

umask 077
SITE_BACKUP_DIR="$BACKUP_ROOT/$SITE_NAME"
mkdir -p "$SITE_BACKUP_DIR"
chmod 700 "$SITE_BACKUP_DIR"

TIMESTAMP=$(date -u '+%Y%m%dT%H%M%SZ')
BACKUP_FILE="$SITE_BACKUP_DIR/${DB_NAME}-${TIMESTAMP}.sql.gz"
PARTIAL_FILE="$BACKUP_FILE.partial"

cleanup_partial() {
  if [ -n "${PARTIAL_FILE:-}" ]; then
    rm -f -- "$PARTIAL_FILE"
  fi
}
trap cleanup_partial EXIT

echo "Creating database backup for $SITE_NAME..."
if ! docker exec mariadb sh -c '
  exec mariadb-dump \
    --single-transaction \
    --quick \
    --skip-lock-tables \
    --default-character-set=utf8mb4 \
    -uroot \
    -p"$MYSQL_ROOT_PASSWORD" \
    --databases "$1"
' sh "$DB_NAME" | gzip -6 > "$PARTIAL_FILE"; then
  die "Database backup failed."
fi

gzip -t "$PARTIAL_FILE"
mv -- "$PARTIAL_FILE" "$BACKUP_FILE"
PARTIAL_FILE=""

RETENTION_MTIME=$((BACKUP_RETENTION_DAYS - 1))
find "$SITE_BACKUP_DIR" -maxdepth 1 -type f \
  -name "${DB_NAME}-*.sql.gz" \
  -mtime "+$RETENTION_MTIME" -delete

echo "Backup created: $BACKUP_FILE"
