#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$REPO_DIR/shared"

echo "=== Base stack setup ==="
echo ""

# ── .env ────────────────────────────────────────────────────────────────────
if [ -f "$BASE_DIR/.env" ]; then
  read -rp "shared/.env already exists. Overwrite? [y/N] " confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
fi

read -rp  "ACME email (for Let's Encrypt notifications): " ACME_EMAIL
read -rsp "Cloudflare DNS API token: " CF_DNS_API_TOKEN; echo
read -rsp "MariaDB root password: " MYSQL_ROOT_PASSWORD; echo

# Verify that the Cloudflare token is active before writing anything
echo ""
echo "Verifying Cloudflare token..."
CF_VERIFY=$(curl -sf "https://api.cloudflare.com/client/v4/user/tokens/verify" \
  -H "Authorization: Bearer $CF_DNS_API_TOKEN" | grep -o '"status":"[^"]*"' | cut -d: -f2 | tr -d '"')

if [ "$CF_VERIFY" != "active" ]; then
  echo "Error: Cloudflare token is invalid or inactive. Aborting."
  exit 1
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
