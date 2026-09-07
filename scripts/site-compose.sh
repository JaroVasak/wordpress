#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/validation.sh
source "$REPO_DIR/scripts/lib/validation.sh"

require_command docker
require_docker_compose

if (( $# < 2 )); then
  die "Usage: $0 <site-name> <docker-compose arguments...>"
fi

SITE_NAME="$1"
shift
is_valid_site_name "$SITE_NAME" || \
  die "Use a lowercase site slug with letters, digits, and single hyphens."

SITE_DIR="$REPO_DIR/sites/$SITE_NAME"
[ -f "$SITE_DIR/docker-compose.yml" ] || \
  die "Site Compose file not found: $SITE_DIR/docker-compose.yml"
[ -f "$SITE_DIR/.env" ] || die "Site environment file not found: $SITE_DIR/.env"

SITE_SECRET_PREFIX=${SITE_NAME^^}
SITE_SECRET_PREFIX=${SITE_SECRET_PREFIX//-/_}
DB_PASSWORD_SECRET="${SITE_SECRET_PREFIX}_DB_PASSWORD"
DB_PASSWORD=${!DB_PASSWORD_SECRET:-}
[ -n "$DB_PASSWORD" ] || \
  die "$DB_PASSWORD_SECRET is missing from the environment."
is_valid_password "$DB_PASSWORD" || \
  die "$DB_PASSWORD_SECRET does not meet the documented input rules."
export DB_PASSWORD

exec docker compose --project-name "$SITE_NAME" \
  -f "$SITE_DIR/docker-compose.yml" "$@"
