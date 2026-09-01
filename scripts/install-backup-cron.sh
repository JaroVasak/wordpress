#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/validation.sh
source "$REPO_DIR/scripts/lib/validation.sh"

require_command cron
require_command install
require_command mktemp

if (( EUID != 0 )); then
  die "Run this command as root, for example with sudo."
fi

if (( $# < 1 || $# > 3 )); then
  die "Usage: $0 <site-name> [backup-root] [retention-days]"
fi

SITE_NAME="$1"
BACKUP_ROOT="${2:-/var/backups/wordpress}"
BACKUP_RETENTION_DAYS="${3:-14}"

is_valid_site_name "$SITE_NAME" || \
  die "Use a lowercase site slug with letters, digits, and single hyphens."
is_positive_integer "$BACKUP_RETENTION_DAYS" || \
  die "Retention days must be a positive integer."
[[ "$BACKUP_ROOT" == /* ]] || die "The backup root must be an absolute path."

for cron_path in "$REPO_DIR" "$BACKUP_ROOT"; do
  [[ "$cron_path" != *$'\n'* && "$cron_path" != *"'"* && \
    "$cron_path" != *%* ]] || \
    die "Repository and backup paths cannot contain newlines, single quotes, or %."
done

SITE_DIR="$REPO_DIR/sites/$SITE_NAME"
[ -d "$SITE_DIR" ] || die "Site directory not found: $SITE_DIR"
[ -f "$SITE_DIR/.env" ] || die "Site environment file not found: $SITE_DIR/.env"
[ -x "$REPO_DIR/scripts/backup-site.sh" ] || \
  die "scripts/backup-site.sh is not executable."
[ -d /etc/cron.d ] || die "/etc/cron.d is not available."

install -d -m 700 "$BACKUP_ROOT/$SITE_NAME"

CRON_NAME="wordpress-db-backup-$SITE_NAME"
CRON_FILE="/etc/cron.d/$CRON_NAME"
TEMP_FILE=$(mktemp "/etc/cron.d/.${CRON_NAME}.XXXXXX")

cleanup_temp() {
  if [ -n "${TEMP_FILE:-}" ]; then
    rm -f -- "$TEMP_FILE"
  fi
}
trap cleanup_temp EXIT

cat > "$TEMP_FILE" <<EOF
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

0 3 * * * root BACKUP_RETENTION_DAYS=$BACKUP_RETENTION_DAYS '$REPO_DIR/scripts/backup-site.sh' '$SITE_NAME' '$BACKUP_ROOT'
EOF

chown root:root "$TEMP_FILE"
chmod 644 "$TEMP_FILE"
mv -- "$TEMP_FILE" "$CRON_FILE"
TEMP_FILE=""

echo "Installed database backup schedule: $CRON_FILE"
echo "Schedule: daily at 03:00"
echo "Backup directory: $BACKUP_ROOT/$SITE_NAME"
