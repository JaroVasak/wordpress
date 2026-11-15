#!/usr/bin/env bash
set -euo pipefail

if (( $# != 2 )); then
  echo "Usage: $0 <image-reference> <unfiltered-report.json>" >&2
  exit 1
fi

POLICY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REVIEW="$POLICY_DIR/mariadb-gosu-review.json"
IMAGE_REF="$1"
REPORT="$2"

# Other images always receive the complete, unexcepted gate.
[[ "$IMAGE_REF" == "$(jq -er '.image' "$REVIEW")" ]] || exit 0
DIGEST=$(jq -er '.Metadata.RepoDigests[0]' "$REPORT")
[[ "$DIGEST" =~ ^mariadb@sha256:[a-f0-9]{64}$ ]] || {
  echo 'Invalid MariaDB digest in the unfiltered scan report.' >&2
  exit 1
}

TEMP_DIR=$(mktemp -d "${RUNNER_TEMP:-/tmp}/wordpress-gosu-review.XXXXXX")
CONTAINER=""
cleanup() {
  if [[ -n "$CONTAINER" ]]; then
    docker rm --volumes "$CONTAINER" > /dev/null
  fi
  rm -rf -- "$TEMP_DIR"
}
trap cleanup EXIT

# Inspect files from the immutable scanned image without executing its binaries.
docker pull --quiet "$DIGEST" >&2
CONTAINER=$(docker create --entrypoint /bin/true "$DIGEST")
if ! docker cp "$CONTAINER:/usr/local/bin/gosu" "$TEMP_DIR/gosu" > /dev/null; then
  echo 'No reviewed helper found; applying the complete gate.' >&2
  exit 0
fi
ACTUAL_SHA=$(sha256sum "$TEMP_DIR/gosu" | awk '{print $1}')
EXPECTED_SHA=$(jq -er '.binary_sha256' "$REVIEW")
if [[ "$ACTUAL_SHA" == "$EXPECTED_SHA" ]]; then
  printf '%s\n' "$POLICY_DIR/mariadb-gosu.trivyignore.yaml"
else
  echo 'Helper differs from the reviewed binary; applying the complete gate.' >&2
fi
