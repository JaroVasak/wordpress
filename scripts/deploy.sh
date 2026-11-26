#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATE_DIR="$REPO_DIR/templates/site"
SITES_DIR="$REPO_DIR/sites"
ROLLOUT_LIST="$SITES_DIR/rollout.list"
# shellcheck source=scripts/lib/validation.sh
source "$REPO_DIR/scripts/lib/validation.sh"

DEPLOY_BRANCH=${DEPLOY_BRANCH:-main}
STATE_DIR=${DEPLOY_STATE_DIR:-/var/lib/wordpress-deploy}
BACKUP_ROOT=${DEPLOY_BACKUP_ROOT:-/var/backups/wordpress}
# Minimum time a version must run on the canary before the other sites take it.
# 20 hours lets a daily timer promote yesterday's canary version.
SOAK_HOURS=${DEPLOY_SOAK_HOURS:-20}
LOCK_FILE=/run/lock/wordpress-deploy.lock
HEALTH_ATTEMPTS=6
HEALTH_INTERVAL=10
# Traefik answers 404 for a site until it has registered the recreated container.
ROUTE_SETTLE_SECONDS=10
WAIT_TIMEOUT=180

# Files owned by the template in every site directory. Everything else in a site
# directory (.env, wp-content/, nginx.d/, php.d/, compose.override.yml) is per-site.
MANAGED_FILES=(docker-compose.yml nginx.conf php-fpm.conf uploads.ini)
# Path of the site's database password inside its running PHP-FPM container.
CONTAINER_PASSWORD_FILE=/run/secrets/wordpress_db_password

usage() {
  cat <<EOF
Usage: $0 <command> [arguments]

Automatic commands (run by the wordpress-deploy systemd timer):
  fetch               Fast-forward the checkout to origin/$DEPLOY_BRANCH.
  rollout             Move the other listed sites to the canary's version once it
                      has run for $SOAK_HOURS hours, then move the canary (first
                      listed site) to the current template.

Operator commands:
  status              Show the checkout, versions, and each site's last result.
  diff [site]         Show how site files differ from the template (dry run).
  site <site> [--force]
                      Update one site to the template now. --force recreates it
                      even if its files already match the template.
  pause | resume      Stop or restart the automatic fetch and rollout.
  unblock             Allow a version that failed before to be retried.
EOF
}

[[ "$DEPLOY_BRANCH" =~ ^[A-Za-z0-9._/-]+$ ]] || die "DEPLOY_BRANCH is invalid."
[[ "$STATE_DIR" == /* ]] || die "DEPLOY_STATE_DIR must be an absolute path."
[[ "$BACKUP_ROOT" == /* ]] || die "DEPLOY_BACKUP_ROOT must be an absolute path."
[[ "$SOAK_HOURS" =~ ^[0-9]+$ ]] || die "DEPLOY_SOAK_HOURS must be a whole number."

# ── helpers ──────────────────────────────────────────────────────────────────

acquire_lock() {
  require_command flock
  exec {LOCK_FD}>"$LOCK_FILE"
  flock -n "$LOCK_FD" || die "Another deployment is running."
}

ensure_state_dir() {
  install -d -m 700 "$STATE_DIR" "$STATE_DIR/sites"
}

is_paused() {
  [ -f "$STATE_DIR/paused" ]
}

short_commit() {
  git -C "$REPO_DIR" rev-parse --short "$1"
}

load_rollout_sites() {
  local line site seen
  ROLLOUT_SITES=()
  [ -f "$ROLLOUT_LIST" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    site=${line%%#*}
    site=${site//[[:space:]]/}
    [ -n "$site" ] || continue
    is_valid_site_name "$site" || die "Invalid site name in $ROLLOUT_LIST: $site"
    for seen in "${ROLLOUT_SITES[@]}"; do
      [ "$seen" != "$site" ] || die "Site listed twice in $ROLLOUT_LIST: $site"
    done
    ROLLOUT_SITES+=("$site")
  done < "$ROLLOUT_LIST"
}

is_listed() {
  local listed
  for listed in "${ROLLOUT_SITES[@]}"; do
    [ "$listed" != "$1" ] || return 0
  done
  return 1
}

all_site_dirs() {
  local dir
  for dir in "$SITES_DIR"/*/; do
    [ -f "$dir/docker-compose.yml" ] || continue
    dir=${dir%/}
    printf '%s\n' "${dir##*/}"
  done
}

require_site() {
  is_valid_site_name "$1" || \
    die "Use a lowercase site slug with letters, digits, and single hyphens."
  [ -f "$SITES_DIR/$1/.env" ] || die "Site environment file not found: $SITES_DIR/$1/.env"
  [ -f "$SITES_DIR/$1/docker-compose.yml" ] || \
    die "Site Compose file not found: $SITES_DIR/$1/docker-compose.yml"
}

site_env_value() {
  sed -n "s/^$2=//p" "$SITES_DIR/$1/.env" | tail -n 1
}

# A version is the content of the managed files; equal files give equal versions
# whether they are in the template or in a site directory.
files_version() {
  local dir=$1 file
  for file in "${MANAGED_FILES[@]}"; do
    if [ -f "$dir/$file" ]; then
      printf '%s %s\n' "$file" "$(sha256sum < "$dir/$file" | cut -d ' ' -f 1)"
    else
      printf '%s missing\n' "$file"
    fi
  done | sha256sum | cut -c 1-12
}

state_get() {
  local file="$STATE_DIR/sites/$1.state"
  [ -f "$file" ] || return 0
  sed -n "s/^$2=//p" "$file" | tail -n 1
}

# set_state <site> <status> <message> [commit]
# Status "ok" records the site's current files as its verified version. Other
# statuses keep the last verified version and commit.
set_state() {
  local site=$1 status=$2 message=${3//$'\n'/ } commit=${4:-}
  local verified since version tmp
  verified=$(state_get "$site" verified)
  since=$(state_get "$site" verified_since)
  if [ "$status" = ok ]; then
    version=$(files_version "$SITES_DIR/$site")
    if [ "$version" != "$verified" ]; then
      verified=$version
      since=$(date '+%s')
    fi
  fi
  [ -n "$commit" ] || commit=$(state_get "$site" commit)
  ensure_state_dir
  tmp=$(mktemp "$STATE_DIR/sites/.$site.XXXXXX")
  printf 'status=%s\ncommit=%s\nverified=%s\nverified_since=%s\nupdated=%s\nmessage=%s\n' \
    "$status" "$commit" "$verified" "$since" "$(date '+%Y-%m-%d %H:%M %Z')" \
    "$message" > "$tmp"
  mv -- "$tmp" "$STATE_DIR/sites/$site.state"
}

is_blocked() {
  [ -f "$STATE_DIR/blocked" ] && grep -q "^$1 " "$STATE_DIR/blocked"
}

block_version() {
  local version=$1 commit=$2 site=$3
  ensure_state_dir
  is_blocked "$version" || printf '%s %s %s %s\n' "$version" "$(short_commit "$commit")" \
    "$site" "$(date '+%Y-%m-%d')" >> "$STATE_DIR/blocked"
}

check_site_health() {
  local site=$1 domain code="" attempt
  domain=$(site_env_value "$site" DOMAIN)
  is_valid_domain "$domain" || { echo "  $site: DOMAIN in .env is invalid." >&2; return 1; }
  for ((attempt = 1; attempt <= HEALTH_ATTEMPTS; attempt++)); do
    # Ask Traefik on this host directly, bypassing Cloudflare and its cache.
    code=$(curl --silent --output /dev/null --write-out '%{http_code}' --max-time 20 \
      --resolve "$domain:443:127.0.0.1" "https://$domain/") || true
    # Only 2xx and 3xx count: a 404 can be Traefik with no route to the site.
    if [[ "$code" =~ ^[23][0-9][0-9]$ ]]; then
      echo "  $domain: HTTP $code"
      return 0
    fi
    (( attempt == HEALTH_ATTEMPTS )) || sleep "$HEALTH_INTERVAL"
  done
  echo "  $domain: unhealthy (last HTTP status ${code:-none})" >&2
  return 1
}

# ── site update steps ────────────────────────────────────────────────────────

# stage_site <site> <source-dir>: the new managed files plus the site's own config.
stage_site() {
  local site=$1 source=$2 file
  STAGE_DIR="$STATE_DIR/staging/$site"
  rm -rf -- "$STAGE_DIR"
  mkdir -p -- "$STAGE_DIR" || return 1
  for file in "${MANAGED_FILES[@]}"; do
    cp -- "$source/$file" "$STAGE_DIR/$file" || return 1
  done
  cp -- "$SITES_DIR/$site/.env" "$STAGE_DIR/.env" || return 1
  if [ -f "$SITES_DIR/$site/compose.override.yml" ]; then
    cp -- "$SITES_DIR/$site/compose.override.yml" "$STAGE_DIR/" || return 1
  fi
}

staged_compose() {
  local site=$1
  shift
  local files=(-f "$STAGE_DIR/docker-compose.yml")
  if [ -f "$STAGE_DIR/compose.override.yml" ]; then
    files+=(-f "$STAGE_DIR/compose.override.yml")
  fi
  # Validation needs no real password; the placeholder is never used to start anything.
  DB_PASSWORD=validation-placeholder docker compose --project-name "$site" \
    --env-file "$STAGE_DIR/.env" "${files[@]}" "$@"
}

ensure_image() {
  docker image inspect "$1" >/dev/null 2>&1 || docker pull --quiet "$1" >/dev/null
}

# Reads the password from the environment (for example a bws-shell session) or
# from the site's running PHP-FPM container. The value is kept only in memory,
# never printed, logged, written to disk, or passed as a command-line argument.
load_site_password() {
  local site=$1 container secret_var
  secret_var=${site^^}
  secret_var="${secret_var//-/_}_DB_PASSWORD"
  SITE_SECRET_VAR=$secret_var
  SITE_DB_PASSWORD=${!secret_var:-}
  if [ -z "$SITE_DB_PASSWORD" ]; then
    container="$(site_env_value "$site" SITE_NAME)-fpm"
    SITE_DB_PASSWORD=$(docker exec "$container" cat "$CONTAINER_PASSWORD_FILE" \
      2>/dev/null) || SITE_DB_PASSWORD=""
  fi
  is_valid_password "$SITE_DB_PASSWORD"
}

site_compose() {
  local site=$1
  shift
  (
    export "$SITE_SECRET_VAR=$SITE_DB_PASSWORD"
    exec "$REPO_DIR/scripts/site-compose.sh" "$site" "$@"
  )
}

recreate_site() {
  site_compose "$1" up -d --force-recreate --wait --wait-timeout "$WAIT_TIMEOUT" || return 1
  echo "Waiting ${ROUTE_SETTLE_SECONDS}s for Traefik to route to the new containers..."
  sleep "$ROUTE_SETTLE_SECONDS"
}

copy_managed_files() {
  local from=$1 to=$2 file
  for file in "${MANAGED_FILES[@]}"; do
    if [ -f "$from/$file" ]; then
      cp -p -- "$from/$file" "$to/$file" || return 1
    else
      rm -f -- "$to/$file" || return 1
    fi
  done
}

# deploy_site <site> <source-dir> <version> <commit>
# Each step checks its own result: callers use `if`, which disables `set -e`.
deploy_site() {
  local site=$1 source=$2 version=$3 commit=$4 site_dir="$SITES_DIR/$1"
  local previous images nginx_image wordpress_image image
  echo "== $site: updating to version $version (commit $(short_commit "$commit"))"

  if ! stage_site "$site" "$source" || ! staged_compose "$site" config --quiet; then
    block_version "$version" "$commit" "$site"
    set_state "$site" failed "Compose configuration of version $version is invalid; site not changed."
    return 1
  fi

  images=$(staged_compose "$site" config --images) || images=""
  nginx_image=$(sed -n '/^nginx:/p' <<< "$images" | head -n 1)
  wordpress_image=$(sed -n '/^wordpress:/p' <<< "$images" | head -n 1)
  if [ -z "$nginx_image" ] || [ -z "$wordpress_image" ]; then
    set_state "$site" error "Could not determine the site images; site not changed."
    return 1
  fi
  echo "Pulling images..."
  for image in $images; do
    if ! ensure_image "$image"; then
      set_state "$site" error "Could not pull $image; site not changed. Retried next run."
      return 1
    fi
  done

  echo "Validating Nginx and PHP-FPM configuration..."
  mkdir -p -- "$site_dir/nginx.d" "$site_dir/php.d" || return 1
  if ! docker run --rm --network none --add-host wordpress:127.0.0.1 \
      --volume "$STAGE_DIR/nginx.conf:/etc/nginx/conf.d/default.conf:ro" \
      --volume "$site_dir/nginx.d:/etc/nginx/site.d:ro" \
      --entrypoint nginx "$nginx_image" -t ||
    ! docker run --rm --network none \
      --env PHP_INI_SCAN_DIR=:/usr/local/etc/php/site.d \
      --volume "$STAGE_DIR/php-fpm.conf:/usr/local/etc/php-fpm.d/zz-site.conf:ro" \
      --volume "$STAGE_DIR/uploads.ini:/usr/local/etc/php/conf.d/uploads.ini:ro" \
      --volume "$site_dir/php.d:/usr/local/etc/php/site.d:ro" \
      --entrypoint php-fpm "$wordpress_image" -t; then
    block_version "$version" "$commit" "$site"
    set_state "$site" failed "Nginx or PHP-FPM test failed for version $version; site not changed."
    return 1
  fi

  if ! load_site_password "$site"; then
    set_state "$site" manual "Database password unavailable (container not running?). Update by hand: run scripts/deploy.sh site $site in scripts/bws-shell.sh."
    return 1
  fi

  echo "Backing up the database..."
  if ! "$REPO_DIR/scripts/backup-site.sh" "$site" "$BACKUP_ROOT"; then
    set_state "$site" error "Database backup failed; site not changed. Retried next run."
    return 1
  fi

  previous="$STATE_DIR/previous/$site"
  rm -rf -- "$previous"
  if ! mkdir -p -- "$previous" || ! copy_managed_files "$site_dir" "$previous" ||
    ! copy_managed_files "$STAGE_DIR" "$site_dir"; then
    copy_managed_files "$previous" "$site_dir" || true
    set_state "$site" error "Could not install the new files; previous files restored."
    return 1
  fi

  echo "Recreating containers..."
  if recreate_site "$site" && check_site_health "$site"; then
    rm -rf -- "$STAGE_DIR"
    set_state "$site" ok "Updated to version $version." "$commit"
    echo "== $site: updated."
    return 0
  fi

  echo "== $site: update failed. Restoring the previous configuration..." >&2
  block_version "$version" "$commit" "$site"
  if copy_managed_files "$previous" "$site_dir" && recreate_site "$site" &&
    check_site_health "$site"; then
    set_state "$site" failed "Update to version $version failed; rolled back. See journalctl -u wordpress-deploy."
    echo "== $site: rolled back and healthy." >&2
  else
    set_state "$site" rollback-failed "Update and rollback both failed. Fix by hand; previous files are in $previous."
    echo "== $site: ROLLBACK FAILED. Previous files: $previous" >&2
  fi
  return 1
}

# ── commands ─────────────────────────────────────────────────────────────────

cmd_fetch() {
  local branch old new
  require_command git
  ensure_state_dir
  acquire_lock
  if is_paused; then
    echo "Deployment is paused; not fetching. Run '$0 resume' to continue."
    return 0
  fi

  branch=$(git -C "$REPO_DIR" symbolic-ref --quiet --short HEAD) || \
    die "The checkout is not on a branch."
  [ "$branch" = "$DEPLOY_BRANCH" ] || \
    die "The checkout is on '$branch', not '$DEPLOY_BRANCH'."
  [ -z "$(git -C "$REPO_DIR" status --porcelain --untracked-files=no)" ] || \
    die "The checkout has local changes to tracked files; resolve them first."

  old=$(git -C "$REPO_DIR" rev-parse HEAD)
  git -C "$REPO_DIR" fetch --quiet origin "$DEPLOY_BRANCH"
  new=$(git -C "$REPO_DIR" rev-parse FETCH_HEAD)
  if [ "$old" = "$new" ]; then
    echo "Checkout is up to date at $(short_commit "$old")."
    return 0
  fi
  git -C "$REPO_DIR" merge --ff-only --quiet FETCH_HEAD || \
    die "Cannot fast-forward to origin/$DEPLOY_BRANCH; the checkout has diverged."

  echo "Updated checkout $(short_commit "$old")..$(short_commit "$new"):"
  git -C "$REPO_DIR" log --oneline "$old..$new"
  if ! git -C "$REPO_DIR" diff --quiet "$old" "$new" -- shared/; then
    echo "NOTICE: shared/ changed. Shared services are not updated automatically;"
    echo "apply the change with scripts/bootstrap.sh in scripts/bws-shell.sh."
  fi
}

# The first listed site is the canary: it takes each new template version first.
# The other sites (followers) take the canary's version once it has run there for
# SOAK_HOURS, so at most two versions run at a time. Followers are updated before
# the canary, so they never receive a version the canary got in the same run.
cmd_rollout() {
  local commit template_version canary canary_version canary_commit verified since
  local site follow_reason="" canary_pending=false act_followers=false act_canary=false
  local unhealthy=false
  local -a followers=() pending=()
  require_command curl
  require_command docker
  require_docker_compose
  ensure_state_dir
  acquire_lock
  if is_paused; then
    echo "Deployment is paused; no site is updated. Run '$0 resume' to continue."
    return 0
  fi

  load_rollout_sites
  if (( ${#ROLLOUT_SITES[@]} == 0 )); then
    echo "No sites are listed in $ROLLOUT_LIST; nothing to update."
    return 0
  fi
  for site in "${ROLLOUT_SITES[@]}"; do
    require_site "$site"
  done
  canary=${ROLLOUT_SITES[0]}
  followers=("${ROLLOUT_SITES[@]:1}")

  commit=$(git -C "$REPO_DIR" rev-parse HEAD)
  template_version=$(files_version "$TEMPLATE_DIR")
  canary_version=$(files_version "$SITES_DIR/$canary")
  if [ "$canary_version" = "$template_version" ]; then
    if [ "$(state_get "$canary" verified)" != "$canary_version" ]; then
      set_state "$canary" ok "Matches the template." "$commit"
    fi
  else
    canary_pending=true
  fi

  # Followers may only copy a version the canary reached through a healthy update.
  canary_commit=$(state_get "$canary" commit)
  verified=$(state_get "$canary" verified)
  since=$(state_get "$canary" verified_since)
  if [ "$canary_version" != "$verified" ]; then
    follow_reason="$canary has no healthy update recorded for its current files"
  elif is_blocked "$canary_version"; then
    follow_reason="version $canary_version failed on a site"
  elif (( $(date '+%s') - ${since:-0} < SOAK_HOURS * 3600 )); then
    follow_reason="version $canary_version has run on $canary for less than $SOAK_HOURS hours"
  fi
  for site in "${followers[@]}"; do
    if [ "$(files_version "$SITES_DIR/$site")" = "$canary_version" ]; then
      if [ -z "$follow_reason" ] && [ "$(state_get "$site" verified)" != "$canary_version" ]; then
        set_state "$site" ok "Matches the canary version." "$canary_commit"
      fi
    else
      pending+=("$site")
    fi
  done

  if (( ${#pending[@]} > 0 )); then
    if [ -z "$follow_reason" ]; then
      act_followers=true
    else
      echo "Waiting: ${pending[*]} stay on their version because $follow_reason."
    fi
  fi
  if [ "$canary_pending" = true ]; then
    if is_blocked "$template_version"; then
      echo "Waiting: template version $template_version failed before; $canary stays."
      echo "Merge a fix, or run '$0 unblock' to retry it."
    else
      act_canary=true
    fi
  fi
  if [ "$act_followers" = false ] && [ "$act_canary" = false ]; then
    echo "Nothing to update. Canary $canary: $canary_version; template: $template_version."
    return 0
  fi

  echo "Checking that all listed sites are healthy before updating..."
  for site in "${ROLLOUT_SITES[@]}"; do
    check_site_health "$site" || unhealthy=true
  done
  [ "$unhealthy" = false ] || die "A listed site is unhealthy; no site was updated."

  if [ "$act_followers" = true ]; then
    for site in "${pending[@]}"; do
      if ! deploy_site "$site" "$SITES_DIR/$canary" "$canary_version" "$canary_commit"; then
        unset SITE_DB_PASSWORD
        die "Update of $site failed; the remaining sites and the canary are not updated."
      fi
    done
  fi
  if [ "$act_canary" = true ]; then
    if ! deploy_site "$canary" "$TEMPLATE_DIR" "$template_version" "$commit"; then
      unset SITE_DB_PASSWORD
      die "Update of canary $canary failed; the other sites keep their version."
    fi
  fi
  unset SITE_DB_PASSWORD
}

cmd_site() {
  local site=${1:-} force=${2:-} commit version
  [ -n "$site" ] || die "Usage: $0 site <site> [--force]"
  [ -z "$force" ] || [ "$force" = --force ] || die "Usage: $0 site <site> [--force]"
  require_site "$site"
  require_command curl
  require_command docker
  require_docker_compose
  ensure_state_dir
  acquire_lock

  commit=$(git -C "$REPO_DIR" rev-parse HEAD)
  version=$(files_version "$TEMPLATE_DIR")
  if [ "$(files_version "$SITES_DIR/$site")" = "$version" ] && [ -z "$force" ]; then
    set_state "$site" ok "Matches the template." "$commit"
    echo "$site already matches the template. Use --force to recreate it anyway."
    return 0
  fi
  if ! deploy_site "$site" "$TEMPLATE_DIR" "$version" "$commit"; then
    unset SITE_DB_PASSWORD
    die "Update of $site failed."
  fi
  unset SITE_DB_PASSWORD
}

cmd_diff() {
  local site file extra
  local -a sites
  load_rollout_sites
  if (( $# > 0 )); then
    require_site "$1"
    sites=("$1")
  else
    mapfile -t sites < <(all_site_dirs)
  fi
  (( ${#sites[@]} > 0 )) || { echo "No sites found in $SITES_DIR."; return 0; }

  for site in "${sites[@]}"; do
    if is_listed "$site"; then
      echo "=== $site (in rollout.list)"
    else
      echo "=== $site (not in rollout.list; never updated automatically)"
    fi
    if [ "$(files_version "$SITES_DIR/$site")" = "$(files_version "$TEMPLATE_DIR")" ]; then
      echo "Managed files match the template."
    else
      for file in "${MANAGED_FILES[@]}"; do
        diff -u --label "sites/$site/$file" --label "templates/site/$file" \
          "$SITES_DIR/$site/$file" "$TEMPLATE_DIR/$file" || true
      done
    fi
    for extra in "$SITES_DIR/$site"/nginx.d/*.conf "$SITES_DIR/$site"/php.d/*.ini \
      "$SITES_DIR/$site/compose.override.yml"; do
      if [ -f "$extra" ]; then
        echo "Override kept: ${extra#"$SITES_DIR/"}"
      fi
    done
    echo
  done
}

cmd_status() {
  local site role version status commit updated message shared_change template_version
  local canary_version=""
  load_rollout_sites
  template_version=$(files_version "$TEMPLATE_DIR")
  echo "Checkout:  $(git -C "$REPO_DIR" log -1 --format='%h %cs %s') ($(git -C "$REPO_DIR" \
    symbolic-ref --quiet --short HEAD || echo detached))"
  echo "Template:  version $template_version"
  shared_change=$(git -C "$REPO_DIR" log -1 --format='%h %cs %s' -- shared/)
  echo "shared/:   last changed in ${shared_change:-?} (applied by hand)"
  if is_paused; then
    echo "Automatic: PAUSED"
  else
    echo "Automatic: active, followers wait $SOAK_HOURS hours after the canary"
  fi
  if command -v systemctl >/dev/null 2>&1 &&
    systemctl is-enabled --quiet wordpress-deploy.timer 2>/dev/null; then
    echo "Timer:     next run $(systemctl show wordpress-deploy.timer \
      --property=NextElapseUSecRealtime --value)"
  else
    echo "Timer:     not installed (see scripts/install-deploy-timer.sh)"
  fi
  if [ -s "$STATE_DIR/blocked" ]; then
    echo "Blocked versions (version, commit, site, date):"
    sed 's/^/  /' "$STATE_DIR/blocked"
  fi
  echo

  if (( ${#ROLLOUT_SITES[@]} == 0 )); then
    echo "No sites are listed in $ROLLOUT_LIST."
  else
    canary_version=$(files_version "$SITES_DIR/${ROLLOUT_SITES[0]}")
  fi
  for site in "${ROLLOUT_SITES[@]}"; do
    role=follower
    [ "$site" != "${ROLLOUT_SITES[0]}" ] || role=canary
    version=$(files_version "$SITES_DIR/$site")
    if [ "$version" = "$template_version" ]; then
      version="$version (template)"
    elif [ "$role" = follower ] && [ "$version" = "$canary_version" ]; then
      version="$version (canary)"
    fi
    status=$(state_get "$site" status)
    commit=$(state_get "$site" commit)
    updated=$(state_get "$site" updated)
    message=$(state_get "$site" message)
    if [ -n "$commit" ]; then
      commit=$(short_commit "$commit" 2>/dev/null || echo "$commit")
    fi
    printf '%-26s %-8s %-24s %-15s commit %-9s %s\n' "$site" "$role" "$version" \
      "${status:-never}" "${commit:--}" "${updated:-}"
    [ -z "$message" ] || echo "  $message"
  done
  while IFS= read -r site; do
    is_listed "$site" || echo "$site: not in rollout.list"
  done < <(all_site_dirs)
}

cmd_pause() {
  ensure_state_dir
  touch "$STATE_DIR/paused"
  echo "Automatic fetch and rollout are paused."
}

cmd_resume() {
  rm -f -- "$STATE_DIR/paused"
  echo "Automatic fetch and rollout are active."
}

cmd_unblock() {
  rm -f -- "$STATE_DIR/blocked"
  echo "Failed versions can be retried by the next rollout."
}

COMMAND=${1:-}
(( $# == 0 )) || shift
case "$COMMAND" in
  fetch) (( $# == 0 )) || die "Usage: $0 fetch"; cmd_fetch ;;
  rollout) (( $# == 0 )) || die "Usage: $0 rollout"; cmd_rollout ;;
  site) cmd_site "$@" ;;
  diff) (( $# <= 1 )) || die "Usage: $0 diff [site]"; cmd_diff "$@" ;;
  status) cmd_status ;;
  pause) cmd_pause ;;
  resume) cmd_resume ;;
  unblock) cmd_unblock ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
