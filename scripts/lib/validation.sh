#!/usr/bin/env bash

# Shared validation and dependency helpers for repository automation scripts.

die() {
  printf 'Error: %s\n' "$1" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

require_docker_compose() {
  docker compose version >/dev/null 2>&1 || \
    die "Docker Compose is not available."
}

is_valid_domain() {
  local domain="$1"
  local label
  local -a labels

  (( ${#domain} <= 253 )) || return 1
  [[ "$domain" == "${domain,,}" ]] || return 1
  [[ "$domain" == *.* ]] || return 1
  [[ "$domain" != .* && "$domain" != *. && "$domain" != *..* ]] || return 1

  IFS='.' read -r -a labels <<< "$domain"
  for label in "${labels[@]}"; do
    (( ${#label} >= 1 && ${#label} <= 63 )) || return 1
    [[ "$label" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || return 1
  done
}

is_valid_email() {
  local email="$1"
  local local_part="${email%@*}"
  local domain="${email##*@}"

  (( ${#email} <= 254 )) || return 1
  (( ${#local_part} >= 1 && ${#local_part} <= 64 )) || return 1
  [[ "$local_part" =~ ^[A-Za-z0-9._%+-]+$ ]] || return 1
  is_valid_domain "$domain"
}

is_valid_cloudflare_token() {
  local token="$1"

  (( ${#token} >= 1 && ${#token} <= 512 )) || return 1
  [[ "$token" =~ ^[A-Za-z0-9_-]+$ ]]
}

is_valid_password() {
  local password="$1"

  (( ${#password} >= 16 && ${#password} <= 128 )) || return 1
  [[ "$password" =~ ^[A-Za-z0-9._~!@%^+=,:/-]+$ ]]
}

is_valid_site_name() {
  local site_name="$1"

  (( ${#site_name} >= 1 && ${#site_name} <= 63 )) || return 1
  [[ "$site_name" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]]
}

is_valid_db_name() {
  local db_name="$1"

  (( ${#db_name} >= 1 && ${#db_name} <= 64 )) || return 1
  [[ "$db_name" =~ ^[A-Za-z0-9_]+$ ]]
}

is_valid_db_user() {
  local db_user="$1"

  (( ${#db_user} >= 1 && ${#db_user} <= 32 )) || return 1
  [[ "$db_user" =~ ^[A-Za-z0-9_]+$ ]]
}
