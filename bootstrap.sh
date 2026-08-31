#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$REPO_DIR/shared"
# shellcheck source=scripts/lib/validation.sh
source "$REPO_DIR/scripts/lib/validation.sh"

require_command curl
require_command docker
require_docker_compose

echo "=== Base stack setup ==="
echo ""

# ── .env ────────────────────────────────────────────────────────────────────
if [ -f "$BASE_DIR/.env" ]; then
  read -rp "shared/.env already exists. Overwrite? [y/N] " confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
fi

read -rp "ACME email (for Let's Encrypt notifications): " ACME_EMAIL
is_valid_email "$ACME_EMAIL" || \
  die "Enter a valid email address with a lowercase domain."

read -rsp "Cloudflare DNS API token: " CF_DNS_API_TOKEN
echo
is_valid_cloudflare_token "$CF_DNS_API_TOKEN" || \
  die "The Cloudflare token contains unsupported characters."

read -rsp "MariaDB root password: " MYSQL_ROOT_PASSWORD
echo
is_valid_password "$MYSQL_ROOT_PASSWORD" || \
  die "The MariaDB password does not meet the documented input rules."

# Verify that the Cloudflare token is active before writing anything
echo ""
echo "Verifying Cloudflare token..."
if ! CF_RESPONSE=$(curl -fsS \
  "https://api.cloudflare.com/client/v4/user/tokens/verify" \
  -H "Authorization: Bearer $CF_DNS_API_TOKEN"); then
  die "Cloudflare token verification request failed."
fi

CF_VERIFY=$(printf '%s' "$CF_RESPONSE" | \
  grep -oE '"status"[[:space:]]*:[[:space:]]*"[^"]+"' | \
  head -n 1 | cut -d'"' -f4 || true)

if [ "$CF_VERIFY" != "active" ]; then
  die "Cloudflare token is invalid or inactive."
fi
echo "Token OK."
echo ""

cat > "$BASE_DIR/.env" <<EOF
CF_DNS_API_TOKEN=$CF_DNS_API_TOKEN
MYSQL_ROOT_PASSWORD=$MYSQL_ROOT_PASSWORD
ACME_EMAIL=$ACME_EMAIL
EOF
chmod 600 "$BASE_DIR/.env"

# ── acme.json ────────────────────────────────────────────────────────────────
touch "$BASE_DIR/traefik/acme.json"
chmod 600 "$BASE_DIR/traefik/acme.json"

# ── start shared stack ───────────────────────────────────────────────────────
echo "Starting shared stack (Traefik + MariaDB)..."
docker compose -f "$BASE_DIR/docker-compose.yml" up -d

echo ""
echo "Base stack is up."
echo "Run ./new-site.sh to add your first site."
