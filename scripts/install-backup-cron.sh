#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/validation.sh
source "$REPO_DIR/scripts/lib/validation.sh"

require_command cron
require_command install
require_command mktemp
require_command awk
require_command flock

if (( EUID != 0 )); then
  die "Run this command as root, for example with sudo."
fi

if (( $# < 1 || $# > 4 )); then
  die "Usage: $0 <site-name> [backup-root] [retention-days] [HH:MM]"
fi

SITE_NAME="$1"
BACKUP_ROOT="${2:-/var/backups/wordpress}"
BACKUP_RETENTION_DAYS="${3:-14}"
BACKUP_TIME="${4:-}"

is_valid_site_name "$SITE_NAME" || \
  die "Use a lowercase site slug with letters, digits, and single hyphens."
is_positive_integer "$BACKUP_RETENTION_DAYS" || \
  die "Retention days must be a positive integer."
if [[ -n "$BACKUP_TIME" ]]; then
  [[ "$BACKUP_TIME" =~ ^([01][0-9]|2[0-3]):([0-5][0-9])$ ]] || \
    die "Backup time must use HH:MM in 24-hour format."
fi
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

CRON_NAME="wordpress-db-backup-$SITE_NAME"
CRON_FILE="/etc/cron.d/$CRON_NAME"

# Serialize slot selection and installation across concurrent site setups.
exec {BACKUP_LOCK_FD}>/run/lock/wordpress-db-backups.lock
flock -x "$BACKUP_LOCK_FD"

read_schedule_time() {
  local schedule_time
  schedule_time=$(awk '
    /^[[:space:]]*($|#)/ { next }
    /^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=/ { next }
    {
      if (NF < 7 || $1 !~ /^[0-9][0-9]?$/ || $1 > 59 ||
          $2 !~ /^[0-9][0-9]?$/ || $2 > 23 ||
          $3 != "*" || $4 != "*" || $5 != "*" || $6 != "root") exit 1
      printf "%02d:%02d\n", $2, $1
      count++
    }
    END { if (count != 1) exit 1 }
  ' "$1") || die "Cannot read a single daily backup time from $1."
  printf '%s\n' "$schedule_time"
}

if [[ -z "$BACKUP_TIME" && -f "$CRON_FILE" ]]; then
  BACKUP_TIME=$(read_schedule_time "$CRON_FILE")
fi

if [[ -z "$BACKUP_TIME" ]]; then
  USED_TIMES=()
  shopt -s nullglob
  for schedule_file in /etc/cron.d/wordpress-db-backup-*; do
    schedule_time=$(read_schedule_time "$schedule_file")
    USED_TIMES+=("$((10#${schedule_time%:*} * 60 + 10#${schedule_time#*:}))")
  done

  # Search daily slots from 03:00, wrapping at midnight, with 15-minute spacing.
  for ((slot = 0; slot < 96; slot++)); do
    candidate=$(((3 * 60 + slot * 15) % 1440))
    available=true
    for used_time in "${USED_TIMES[@]}"; do
      distance=$(((candidate - used_time + 1440) % 1440))
      if (( distance < 15 || distance > 1425 )); then
        available=false
        break
      fi
    done
    if [[ "$available" == true ]]; then
      printf -v BACKUP_TIME '%02d:%02d' "$((candidate / 60))" "$((candidate % 60))"
      break
    fi
  done
  [[ -n "$BACKUP_TIME" ]] || die "No free daily backup slot with 15-minute spacing."
fi

BACKUP_HOUR=$((10#${BACKUP_TIME%:*}))
BACKUP_MINUTE=$((10#${BACKUP_TIME#*:}))
install -d -m 700 "$BACKUP_ROOT/$SITE_NAME"
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

$BACKUP_MINUTE $BACKUP_HOUR * * * root BACKUP_RETENTION_DAYS=$BACKUP_RETENTION_DAYS '$REPO_DIR/scripts/backup-site.sh' '$SITE_NAME' '$BACKUP_ROOT'
EOF

chown root:root "$TEMP_FILE"
chmod 644 "$TEMP_FILE"
mv -- "$TEMP_FILE" "$CRON_FILE"
TEMP_FILE=""

echo "Installed database backup schedule: $CRON_FILE"
echo "Schedule: daily at $BACKUP_TIME (server timezone)"
echo "Backup directory: $BACKUP_ROOT/$SITE_NAME"
