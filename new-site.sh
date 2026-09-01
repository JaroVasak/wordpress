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
COMPOSE_PROJECT_NAME="$SITE_NAME"
SITE_VOLUME="${COMPOSE_PROJECT_NAME}_wordpress_files"
SITE_NETWORK="${COMPOSE_PROJECT_NAME}_internal"

if [ -d "$SITE_DIR" ]; then
  die "$SITE_DIR already exists."
fi

# ── collision checks ──────────────────────────────────────────────────────────
for container_name in "${SITE_NAME}-nginx" "${SITE_NAME}-fpm"; do
  if docker container inspect "$container_name" &>/dev/null; then
    die "Docker container already exists: $container_name"
  fi
done

if docker volume inspect "$SITE_VOLUME" &>/dev/null; then
  die "Docker volume already exists: $SITE_VOLUME"
fi

if docker network inspect "$SITE_NETWORK" &>/dev/null; then
  die "Docker network already exists: $SITE_NETWORK"
fi

mariadb_scalar() {
  docker exec mariadb mariadb --batch --skip-column-names \
    -uroot -p"$MYSQL_ROOT_PASSWORD" -e "$1"
}

if ! DATABASE_EXISTS=$(mariadb_scalar \
  "SELECT COUNT(*) FROM INFORMATION_SCHEMA.SCHEMATA WHERE SCHEMA_NAME = '$DB_NAME';"); then
  die "Could not check whether database $DB_NAME exists."
fi
[[ "$DATABASE_EXISTS" == "0" ]] || die "Database already exists: $DB_NAME"

if ! DB_USER_EXISTS=$(mariadb_scalar \
  "SELECT COUNT(*) FROM mysql.user WHERE User = '$DB_USER' AND Host = '%';"); then
  die "Could not check whether database user $DB_USER exists."
fi
[[ "$DB_USER_EXISTS" == "0" ]] || die "Database user already exists: $DB_USER"

# ── generate secrets ──────────────────────────────────────────────────────────
wp_key() { openssl rand -hex 32; }
TABLE_PREFIX="wp$(openssl rand -hex 3)_"

# ── rollback ──────────────────────────────────────────────────────────────────
SITE_DIR_CREATED=false
DATABASE_CREATED=false
DB_USER_CREATED=false
STACK_START_ATTEMPTED=false

rollback_provisioning() {
  local exit_code=$?
  local cleanup_failed=false
  local expected_site_prefix="$REPO_DIR/sites/"

  (( exit_code != 0 )) || return 0
  trap - EXIT
  set +e

  echo ""
  echo "Provisioning failed. Rolling back resources from this run..." >&2

  if [[ "$STACK_START_ATTEMPTED" == "true" ]]; then
    if ! docker compose --project-name "$COMPOSE_PROJECT_NAME" \
      -f "$SITE_DIR/docker-compose.yml" down --volumes --remove-orphans; then
      echo "Warning: Could not remove the attempted site stack." >&2
      cleanup_failed=true
    fi
  fi

  if [[ "$DB_USER_CREATED" == "true" ]]; then
    if ! mariadb_scalar "DROP USER IF EXISTS '$DB_USER'@'%';" >/dev/null; then
      echo "Warning: Could not remove database user $DB_USER." >&2
      cleanup_failed=true
    fi
  fi

  if [[ "$DATABASE_CREATED" == "true" ]]; then
    if ! mariadb_scalar "DROP DATABASE IF EXISTS \`$DB_NAME\`;" >/dev/null; then
      echo "Warning: Could not remove database $DB_NAME." >&2
      cleanup_failed=true
    fi
  fi

  if [[ "$SITE_DIR_CREATED" == "true" ]]; then
    if [[ "$cleanup_failed" == "true" ]]; then
      echo "Warning: Preserved $SITE_DIR for manual recovery." >&2
    elif [[ "$SITE_DIR" == "$expected_site_prefix"* && \
      "$SITE_DIR" != "$TEMPLATE_DIR" && -d "$SITE_DIR" ]]; then
      rm -rf -- "$SITE_DIR"
    else
      echo "Warning: Refused to remove unexpected path: $SITE_DIR" >&2
    fi
  fi

  exit "$exit_code"
}

trap rollback_provisioning EXIT

# ── copy template ─────────────────────────────────────────────────────────────
SITE_DIR_CREATED=true
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
mariadb_scalar "CREATE DATABASE \`$DB_NAME\`;" >/dev/null
DATABASE_CREATED=true

mariadb_scalar \
  "CREATE USER '$DB_USER'@'%' IDENTIFIED BY '$DB_PASSWORD';" >/dev/null
DB_USER_CREATED=true

mariadb_scalar \
  "GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$DB_USER'@'%';" >/dev/null

# ── bring up site ─────────────────────────────────────────────────────────────
echo "Starting site stack..."
STACK_START_ATTEMPTED=true
docker compose --project-name "$COMPOSE_PROJECT_NAME" \
  -f "$SITE_DIR/docker-compose.yml" up -d
trap - EXIT

echo ""
echo "Done. $DOMAIN should be live once Traefik issues the certificate (up to 1 min)."
