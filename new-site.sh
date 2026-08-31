#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_DIR="$REPO_DIR/sites/example-com"
BASE_ENV="$REPO_DIR/shared/.env"
# shellcheck source=scripts/lib/validation.sh
source "$REPO_DIR/scripts/lib/validation.sh"

require_command docker
require_command openssl
require_docker_compose

[ -d "$TEMPLATE_DIR" ] || die "Site template not found: $TEMPLATE_DIR"
[ -f "$BASE_ENV" ] || die "Run ./bootstrap.sh before creating a site."

echo "=== New site setup ==="
echo ""

# ── check shared stack is running ────────────────────────────────────────────
MARIADB_RUNNING=$(docker inspect --format '{{.State.Running}}' mariadb 2>/dev/null || true)
[[ "$MARIADB_RUNNING" == "true" ]] || \
  die "MariaDB is not running. Run ./bootstrap.sh first."

MYSQL_ROOT_PASSWORD=$(sed -n 's/^MYSQL_ROOT_PASSWORD=//p' "$BASE_ENV" | tail -n 1)
[ -n "$MYSQL_ROOT_PASSWORD" ] || \
  die "MYSQL_ROOT_PASSWORD is missing from shared/.env."

echo "Waiting for MariaDB to be ready..."
MARIADB_READY=false
for ((attempt = 1; attempt <= 60; attempt++)); do
  if docker exec mariadb mariadb -uroot -p"$MYSQL_ROOT_PASSWORD" \
    -e "SELECT 1" &>/dev/null; then
    MARIADB_READY=true
    break
  fi
  printf '.'
  sleep 2
done
if [[ "$MARIADB_READY" != "true" ]]; then
  echo
  die "MariaDB did not become ready within two minutes."
fi
echo " ready."
echo ""

# ── prompts ──────────────────────────────────────────────────────────────────
read -rp "Site name slug (e.g. example-com): " SITE_NAME
is_valid_site_name "$SITE_NAME" || \
  die "Use a lowercase slug with letters, digits, and single hyphens."

read -rp "Domain (e.g. example.com): " DOMAIN
is_valid_domain "$DOMAIN" || \
  die "Enter a valid lowercase domain name."

read -rp "DB name (e.g. example_com): " DB_NAME
is_valid_db_name "$DB_NAME" || \
  die "Use at most 64 letters, digits, or underscores for the DB name."

read -rp "DB user (e.g. example_com_user): " DB_USER
is_valid_db_user "$DB_USER" || \
  die "Use at most 32 letters, digits, or underscores for the DB user."

read -rsp "DB password: " DB_PASSWORD
echo
is_valid_password "$DB_PASSWORD" || \
  die "The database password does not meet the documented input rules."

SITE_DIR="$REPO_DIR/sites/$SITE_NAME"

if [ -d "$SITE_DIR" ]; then
  echo "Error: $SITE_DIR already exists."
  exit 1
fi

# ── generate secrets ──────────────────────────────────────────────────────────
wp_key() { openssl rand -hex 32; }
TABLE_PREFIX="wp$(openssl rand -hex 3)_"

# ── copy template ─────────────────────────────────────────────────────────────
cp -r "$TEMPLATE_DIR" "$SITE_DIR"
mkdir -p "$SITE_DIR/wp-content"

# ── write site .env ───────────────────────────────────────────────────────────
cat > "$SITE_DIR/.env" <<EOF
SITE_NAME=$SITE_NAME
DOMAIN=$DOMAIN
DB_NAME=$DB_NAME
DB_USER=$DB_USER
DB_PASSWORD=$DB_PASSWORD
WORDPRESS_TABLE_PREFIX=$TABLE_PREFIX
WORDPRESS_AUTH_KEY=$(wp_key)
WORDPRESS_SECURE_AUTH_KEY=$(wp_key)
WORDPRESS_LOGGED_IN_KEY=$(wp_key)
WORDPRESS_NONCE_KEY=$(wp_key)
WORDPRESS_AUTH_SALT=$(wp_key)
WORDPRESS_SECURE_AUTH_SALT=$(wp_key)
WORDPRESS_LOGGED_IN_SALT=$(wp_key)
WORDPRESS_NONCE_SALT=$(wp_key)
EOF
chmod 600 "$SITE_DIR/.env"

# All SQL values below passed the strict allowlists above.
# ── create database and user in MariaDB ───────────────────────────────────────
echo ""
echo "Creating database and user in MariaDB..."
docker exec -i mariadb mariadb -uroot -p"$MYSQL_ROOT_PASSWORD" <<SQL
CREATE DATABASE IF NOT EXISTS \`$DB_NAME\`;
CREATE USER IF NOT EXISTS '$DB_USER'@'%' IDENTIFIED BY '$DB_PASSWORD';
GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$DB_USER'@'%';
FLUSH PRIVILEGES;
SQL

# ── bring up site ─────────────────────────────────────────────────────────────
echo "Starting site stack..."
docker compose -f "$SITE_DIR/docker-compose.yml" up -d

echo ""
echo "Done. $DOMAIN should be live once Traefik issues the certificate (up to 1 min)."
