#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASE_DIR="$REPO_DIR/shared"
# shellcheck source=scripts/lib/validation.sh
source "$REPO_DIR/scripts/lib/validation.sh"

require_command curl
require_command docker
require_docker_compose

[ -n "${CF_DNS_API_TOKEN:-}" ] || \
  die "CF_DNS_API_TOKEN is missing from the environment."
[ -n "${MYSQL_ROOT_PASSWORD:-}" ] || \
  die "MYSQL_ROOT_PASSWORD is missing from the environment."

is_valid_cloudflare_token "$CF_DNS_API_TOKEN" || \
  die "CF_DNS_API_TOKEN contains unsupported characters."
is_valid_password "$MYSQL_ROOT_PASSWORD" || \
  die "MYSQL_ROOT_PASSWORD does not meet the documented input rules."

echo "=== Base stack setup ==="
echo ""

# ── .env ────────────────────────────────────────────────────────────────────
if [ -f "$BASE_DIR/.env" ]; then
  read -rp "shared/.env already exists. Overwrite? [y/N] " confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
fi

if [ -z "${ACME_EMAIL:-}" ]; then
  read -rp "ACME email (for Let's Encrypt notifications): " ACME_EMAIL
fi
is_valid_email "$ACME_EMAIL" || \
  die "Enter a valid email address with a lowercase domain."

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
ACME_EMAIL=$ACME_EMAIL
EOF
chmod 600 "$BASE_DIR/.env"

# ── acme.json ────────────────────────────────────────────────────────────────
touch "$BASE_DIR/traefik/acme.json"
chmod 600 "$BASE_DIR/traefik/acme.json"

# ── start shared stack ───────────────────────────────────────────────────────
echo "Starting shared stack (socket proxy + Traefik + MariaDB)..."
docker compose -f "$BASE_DIR/docker-compose.yml" \
  up -d --wait --wait-timeout 120

echo ""
echo "Base stack is ready."
echo "Run '$REPO_DIR/scripts/new-site.sh' to add a site."
