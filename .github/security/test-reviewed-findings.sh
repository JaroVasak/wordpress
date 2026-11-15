#!/usr/bin/env bash
set -euo pipefail

SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DIR=$(mktemp -d)
trap 'rm -rf -- "$TEST_DIR"' EXIT
mkdir -p "$TEST_DIR/policy" "$TEST_DIR/bin"
cp "$SOURCE_DIR/select-reviewed-findings.sh" "$SOURCE_DIR/mariadb-gosu.trivyignore.yaml" "$TEST_DIR/policy/"
printf 'reviewed helper fixture\n' > "$TEST_DIR/helper"
FIXTURE_SHA=$(sha256sum "$TEST_DIR/helper" | awk '{print $1}')
jq --arg sha "$FIXTURE_SHA" '.binary_sha256 = $sha' \
  "$SOURCE_DIR/mariadb-gosu-review.json" > "$TEST_DIR/policy/mariadb-gosu-review.json"
cat > "$TEST_DIR/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
set -euo pipefail
case "$1" in
  pull) exit 0 ;;
  create) echo fixture-container ;;
  cp) cp "$FIXTURE_HELPER" "$3" ;;
  rm) exit 0 ;;
  *) exit 99 ;;
esac
DOCKER
chmod +x "$TEST_DIR/bin/docker"
export PATH="$TEST_DIR/bin:$PATH" FIXTURE_HELPER="$TEST_DIR/helper"
SELECTOR="$TEST_DIR/policy/select-reviewed-findings.sh"
printf '{"Metadata":{"RepoDigests":["mariadb@sha256:%064d"]}}\n' 0 > "$TEST_DIR/report.json"
IMAGE=$(jq -r '.image' "$SOURCE_DIR/mariadb-gosu-review.json")

[ "$(bash "$SELECTOR" "$IMAGE" "$TEST_DIR/report.json")" = "$TEST_DIR/policy/mariadb-gosu.trivyignore.yaml" ]
printf 'changed helper\n' > "$TEST_DIR/helper"
[ -z "$(bash "$SELECTOR" "$IMAGE" "$TEST_DIR/report.json")" ]
[ -z "$(bash "$SELECTOR" nginx:unreviewed "$TEST_DIR/report.json")" ]
printf '{"Metadata":{"RepoDigests":["untrusted:tag"]}}\n' > "$TEST_DIR/report.json"
if bash "$SELECTOR" "$IMAGE" "$TEST_DIR/report.json"; then
  echo 'Invalid report unexpectedly accepted.' >&2
  exit 1
fi

# Every exclusion must have matching evidence; no new CVE is implicitly covered.
jq -er '.findings[] | select((.go_ids | length) > 0 and (.present_vulnerable_symbols | length) == 0) | .cve' \
  "$SOURCE_DIR/mariadb-gosu-review.json" | sort > "$TEST_DIR/reviewed-ids"
awk '/^  - id:/ {print $3}' "$SOURCE_DIR/mariadb-gosu.trivyignore.yaml" | sort > "$TEST_DIR/excluded-ids"
cmp "$TEST_DIR/reviewed-ids" "$TEST_DIR/excluded-ids"
[ "$(wc -l < "$TEST_DIR/excluded-ids")" = "$(sort -u "$TEST_DIR/excluded-ids" | wc -l)" ]
echo 'Reviewed-finding scope checks passed.'
