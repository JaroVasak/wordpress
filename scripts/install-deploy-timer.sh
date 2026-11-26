#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/validation.sh
source "$REPO_DIR/scripts/lib/validation.sh"

require_command systemctl
require_command install
require_command mktemp

if (( EUID != 0 )); then
  die "Run this command as root, for example with sudo."
fi

if (( $# > 2 )); then
  die "Usage: $0 [HH:MM] [timezone]"
fi

DEPLOY_TIME="${1:-06:00}"
DEPLOY_TIMEZONE="${2:-Europe/Prague}"

[[ "$DEPLOY_TIME" =~ ^([01][0-9]|2[0-3]):([0-5][0-9])$ ]] || \
  die "Deployment time must use HH:MM in 24-hour format."
[[ "$DEPLOY_TIMEZONE" =~ ^[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+)*$ && \
  -f "/usr/share/zoneinfo/$DEPLOY_TIMEZONE" ]] || \
  die "Unknown timezone: $DEPLOY_TIMEZONE"
[[ "$REPO_DIR" =~ ^/[A-Za-z0-9._/-]+$ ]] || \
  die "The repository path may contain only letters, digits, '.', '_', '-', and '/'."
[ -x "$REPO_DIR/scripts/deploy.sh" ] || die "scripts/deploy.sh is not executable."

UNIT_DIR=/etc/systemd/system
SERVICE_FILE="$UNIT_DIR/wordpress-deploy.service"
TIMER_FILE="$UNIT_DIR/wordpress-deploy.timer"
TEMP_DIR=$(mktemp -d)
trap 'rm -rf -- "$TEMP_DIR"' EXIT

cat > "$TEMP_DIR/service" <<EOF
[Unit]
Description=Update WordPress sites from the repository (canary first, others a day later)
Documentation=file://$REPO_DIR/scripts/README.md
Wants=network-online.target docker.service
After=network-online.target docker.service

[Service]
Type=oneshot
WorkingDirectory=$REPO_DIR
ExecStart=$REPO_DIR/scripts/deploy.sh fetch
ExecStart=$REPO_DIR/scripts/deploy.sh rollout
TimeoutStartSec=30min
EOF

cat > "$TEMP_DIR/timer" <<EOF
[Unit]
Description=Daily WordPress site update at $DEPLOY_TIME $DEPLOY_TIMEZONE

[Timer]
OnCalendar=*-*-* $DEPLOY_TIME:00 $DEPLOY_TIMEZONE
# A run missed while the server was off is skipped, not started at boot.
Persistent=false

[Install]
WantedBy=timers.target
EOF

install -m 644 -o root -g root "$TEMP_DIR/service" "$SERVICE_FILE"
install -m 644 -o root -g root "$TEMP_DIR/timer" "$TIMER_FILE"
systemctl daemon-reload
systemctl enable --now wordpress-deploy.timer

echo "Installed $SERVICE_FILE and $TIMER_FILE."
echo "Schedule: daily at $DEPLOY_TIME ($DEPLOY_TIMEZONE)."
systemctl list-timers wordpress-deploy.timer --no-pager
