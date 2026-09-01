#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/validation.sh
source "$REPO_DIR/scripts/lib/validation.sh"

require_command bash
require_command docker
require_command git
require_command shellcheck
require_docker_compose

SHELL_SCRIPTS=(
  "$REPO_DIR/scripts/bootstrap.sh"
  "$REPO_DIR/scripts/new-site.sh"
  "$REPO_DIR/scripts/backup-site.sh"
  "$REPO_DIR/scripts/install-backup-cron.sh"
  "$REPO_DIR/scripts/validate.sh"
  "$REPO_DIR/scripts/lib/validation.sh"
)

echo "Checking Bash syntax..."
bash -n "${SHELL_SCRIPTS[@]}"

echo "Running ShellCheck..."
shellcheck -P "$REPO_DIR" "${SHELL_SCRIPTS[@]}"

echo "Checking Docker Compose configuration..."
docker compose --env-file "$REPO_DIR/shared/.env.example" \
  -f "$REPO_DIR/shared/docker-compose.yml" config --quiet
docker compose --env-file "$REPO_DIR/sites/example-com/.env.example" \
  -f "$REPO_DIR/sites/example-com/docker-compose.yml" config --quiet
docker compose --env-file "$REPO_DIR/local/.env.example" \
  -f "$REPO_DIR/local/docker-compose.yml" config --quiet

NGINX_IMAGE=$(docker compose \
  --env-file "$REPO_DIR/sites/example-com/.env.example" \
  -f "$REPO_DIR/sites/example-com/docker-compose.yml" \
  config --images | sed -n '/^nginx:/p' | head -n 1)
[ -n "$NGINX_IMAGE" ] || die "Could not determine the Nginx image."

echo "Checking production Nginx configuration..."
docker run --rm --add-host wordpress:127.0.0.1 \
  --volume \
  "$REPO_DIR/sites/example-com/nginx.conf:/etc/nginx/conf.d/default.conf:ro" \
  --entrypoint nginx "$NGINX_IMAGE" -t

echo "Checking local Nginx configuration..."
docker run --rm --add-host wordpress:127.0.0.1 \
  --volume "$REPO_DIR/local/nginx.conf:/etc/nginx/conf.d/default.conf:ro" \
  --entrypoint nginx "$NGINX_IMAGE" -t

echo "Checking Git whitespace..."
git -C "$REPO_DIR" diff HEAD --check

echo "Validation passed."
