#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_DIR="$REPO_DIR/sites/example-com"
BASE_ENV="$REPO_DIR/shared/.env"

echo "=== New site setup ==="
echo ""

# ── check shared stack is running ────────────────────────────────────────────
if ! docker inspect mariadb &>/dev/null; then
  echo "Error: MariaDB container is not running. Run ./bootstrap.sh first."
  exit 1
fi

MYSQL_ROOT_PASSWORD="$(grep '^MYSQL_ROOT_PASSWORD=' "$BASE_ENV" | cut -d= -f2-)"

echo "Waiting for MariaDB to be ready..."
until docker exec mariadb mariadb -uroot -p"$MYSQL_ROOT_PASSWORD" -e "SELECT 1" &>/dev/null 2>&1; do
  printf '.'
  sleep 2
done
echo " ready."
echo ""

# ── prompts ──────────────────────────────────────────────────────────────────
read -rp  "Site name slug (e.g. example-com): " SITE_NAME
read -rp  "Domain (e.g. example.com): " DOMAIN
read -rp  "DB name (e.g. example_com): " DB_NAME
read -rp  "DB user (e.g. example_com_user): " DB_USER
read -rsp "DB password: " DB_PASSWORD; echo

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
