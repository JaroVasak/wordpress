#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CERT_DIR="$REPO_DIR/shared/traefik/certs"
DOMAIN="${1:-example.local}"
HOSTS_ENTRY="127.0.0.1 $DOMAIN www.$DOMAIN"

echo "=== Local certificate setup ==="
echo ""

# ── create certs directory ────────────────────────────────────────────────────
mkdir -p "$CERT_DIR"

# ── generate self-signed certificate ──────────────────────────────────────────
echo "Generating self-signed certificate for *.local..."
openssl req -x509 -newkey rsa:2048 \
  -keyout "$CERT_DIR/server.key" \
  -out "$CERT_DIR/server.crt" \
  -days 365 -nodes \
  -subj "/CN=*.local/O=Local Testing/C=US" \
  2>/dev/null

chmod 600 "$CERT_DIR/server.key"
chmod 644 "$CERT_DIR/server.crt"

echo "✓ Certificate generated:"
echo "  Key:  $CERT_DIR/server.key"
echo "  Cert: $CERT_DIR/server.crt"
echo ""

# ── add hosts entry ───────────────────────────────────────────────────────────
HOSTS_FILE="/etc/hosts"

if grep -q "$DOMAIN" "$HOSTS_FILE" 2>/dev/null; then
  echo "✓ $DOMAIN already in /etc/hosts"
else
  echo "Adding $DOMAIN to /etc/hosts (requires sudo)..."
  echo "$HOSTS_ENTRY" | sudo tee -a "$HOSTS_FILE" > /dev/null
  echo "✓ Added: $HOSTS_ENTRY"
fi

echo ""
echo "Setup complete. You can now:"
echo "  1. cd shared && docker compose -f docker-compose.yml -f docker-compose.local.override.yml up -d"
echo "  2. cd ../sites && ./new-site.sh (when prompted for domain, use: $DOMAIN)"
echo "  3. Visit https://$DOMAIN in your browser"
echo ""
echo "Browser will warn about the certificate (self-signed) — that's expected. Click through."
