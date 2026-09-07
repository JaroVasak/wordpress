#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/validation.sh
source "$REPO_DIR/scripts/lib/validation.sh"

require_command bws

if [ -z "${BWS_ACCESS_TOKEN:-}" ]; then
  read -rsp "Bitwarden machine access token: " BWS_ACCESS_TOKEN
  echo
fi
[ -n "$BWS_ACCESS_TOKEN" ] || die "The machine access token is empty."
export BWS_ACCESS_TOKEN

echo "Starting a shell with injected secrets. Type 'exit' when done."
exec bws run --shell bash -- 'exec bash --noprofile --norc -i'
